import Foundation
import os.log

private let groomingLedgerLog = Logger(subsystem: "ai.kasatkin.kiteloop", category: "grooming-ledger")

/// One thing that happened to an item *before* it ran — it was filed, or a
/// pre-run check judged it and refused it.
///
/// The run side of a night is already on record (`TaskMetricStore`: one line per
/// item run, with its cost and outcome). The grooming side was not on record at
/// all: `DefinitionOfReady` and `GroundingCheck` both refuse items at pickup, and
/// both said so only to the unified log and to a 50-line in-memory buffer that
/// dies with the app. That is the half `PortfolioReport` needs to answer whether
/// the grooming was any good, so it is written down here.
package struct GroomingRecord: Codable, Sendable, Identifiable {

    /// What happened. Filing is split by the stage it landed at, because "filed
    /// 6 items" says nothing until you know how many of them were runnable.
    package enum Event: String, Codable, Sendable {
        /// Filed at `ready` — groomed well enough to be picked up.
        case filedReady = "filed-ready"
        /// Filed at `draft` — filed, but not runnable as it stands.
        case filedDraft = "filed-draft"
        /// A pre-run check refused the item; `check` says which one, `reason` why.
        case checkFailed = "check-failed"
        /// A human released an item a pre-run check had stopped — today only the
        /// retry ceiling, whose refusal is the one a human can lift by hand.
        /// Unlike the others this record is *read* and not merely reported:
        /// `RetryCeiling` discounts the attempts that finished before it.
        case released = "released"
    }

    package var id = UUID().uuidString
    package let at: Date
    package let projectPath: String
    package let projectName: String
    package let itemID: String
    package let event: Event
    /// Which check refused it — `definition-of-ready`, `grounding-check` or
    /// `retry-ceiling`. Nil for a filing.
    package var check: String?
    /// The failing clause, as the verdict phrased it. Nil for a filing.
    package var reason: String?

    /// The memberwise init, spelled out: the synthesized one is internal to the
    /// module, and the app's tests build records. `core-inits.py` skips a Codable
    /// type, whose derived `init(from:)` reads as an init already.
    package init(id: String = UUID().uuidString, at: Date, projectPath: String, projectName: String,
                 itemID: String, event: Event, check: String? = nil, reason: String? = nil) {
        self.id = id
        self.at = at
        self.projectPath = projectPath
        self.projectName = projectName
        self.itemID = itemID
        self.event = event
        self.check = check
        self.reason = reason
    }

    package var isFiled: Bool { event == .filedReady || event == .filedDraft }

    /// The checks that write here, as they appear in `check`. Raw values are
    /// the file's contract — a reader groups by them.
    package enum Check {
        package static let definitionOfReady = "definition-of-ready"
        package static let grounding = "grounding-check"
        /// `RetryCeiling` — the item has been attempted its fill of times
        /// without producing anything. Unlike the other two this is not a
        /// verdict on how the item is written, so a reader grouping refusals by
        /// check can tell "ungroomed" from "groomed and going nowhere".
        package static let retryCeiling = "retry-ceiling"
        /// The draft wrote a `touches:` exemption for itself.
        /// Not a verdict on how the item is written either: the item may be
        /// perfectly groomed and still be parked, because granting an exemption
        /// is a human's decision and a drafter proposing one is only a proposal.
        package static let protectedPathClaim = "protected-path-claim"
    }
}

/// Append-only store of grooming and pre-run check verdicts, JSONL-backed at
/// `~/.kiteloop/grooming.jsonl` — the same shape and write pattern as
/// `TaskMetricStore`, and global for the same reason: the report is a portfolio
/// report, and each record carries its own project.
///
/// Only *failures* are recorded by the checks. A passing check is already visible
/// in what happened next (the item ran), and one line per item per pickup would
/// double the file to say nothing the run record doesn't. A verdict is written to
/// explain a refusal — and, since a human can lift the retry ceiling's refusal, a
/// release is written to explain why one stopped applying.
@Observable
@MainActor
package final class GroomingLedger {

    /// The app-wide ledger. A file log with a single writer, like
    /// `PermissionAuditLogger` — injectable for tests via `init(url:)`.
    package static let shared = GroomingLedger()

    package private(set) var records: [GroomingRecord] = []
    /// Lines the decoder refused, held verbatim so `rewrite()` can put them back.
    /// The ledger is not append-only in practice: a trim replaces the whole file
    /// from `records`, so without this the first trim after a bad line deletes it.
    /// One of them can be a `released` record — the one thing here that is read
    /// back rather than merely reported — and losing it silently re-retires an item
    /// a human deliberately released, which is what `withinRetention` goes out of
    /// its way to prevent for the records it *can* read.
    private var undecodableLines: [String] = []
    /// How many lines could not be read at load. Logged as well, but exposed so a
    /// caller — and a test — can see it without reading os_log, as
    /// `RunRecordStore.undecodableLineCount` and
    /// `TaskMetricStore.undecodableMetricLineCount` are.
    package private(set) var undecodableLineCount = 0
    /// How many writes did not reach the file. The read side has reported its
    /// losses since it was written; the write side used to swallow every error, so
    /// a `~/.kiteloop` that had stopped being writable left a verdict in `records`
    /// and nothing on disk — and a `released` record lost that way re-retires an
    /// item a human deliberately released, with nothing in the file to say why.
    /// Counted as well as logged, like `RunRecordStore.failedWriteCount`, so a
    /// caller can see it without reading os_log.
    package private(set) var failedWriteCount = 0
    private let url: URL

    /// How many records survive. The file is append-only and a run appends to it
    /// every night, so it is trimmed rather than allowed to grow without limit —
    /// the report reads a period, never the whole history.
    package static let retentionLimit = 2000

    package init(url: URL? = nil) {
        self.url = url ?? Self.defaultURL
        let loaded = Self.load(from: self.url)
        self.records = loaded.records
        self.undecodableLines = loaded.undecodable
        self.undecodableLineCount = loaded.undecodable.count
    }

    private static var defaultURL: URL {
        let dir = KiteloopHome.url
            .appendingPathComponent(".kiteloop", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("grooming.jsonl")
    }

    // MARK: - Append

    package func append(_ record: GroomingRecord) {
        records.append(record)
        if records.count > Self.retentionLimit {
            trimToRetention()
            rewrite()
            return
        }
        appendLine(record)
    }

    /// Drops the oldest records, **except releases**.
    private func trimToRetention() {
        records = Self.withinRetention(records)
    }

    /// The retention rule, in one place so the load path and the write path
    /// cannot come to disagree about what "kept" means — the shape
    /// `RunRecordStore.withinBounds(_:now:)` uses for the same reason.
    ///
    /// Drops the oldest records until the limit is met, **except releases**.
    /// Every other record is a report: losing one costs a line in a portfolio
    /// report. A release is read back by `RetryCeiling` on every pickup, so
    /// trimming one would silently re-retire an item a human had deliberately
    /// released — a night's runs on a busy portfolio is enough to roll 2000
    /// records over, and the item would come back retired with nothing in the
    /// file to say why. They are few (one per deliberate human act), so keeping
    /// them all cannot meaningfully outgrow the limit.
    ///
    /// Records stay in the order they came in — oldest first, which is what
    /// `latestRelease(itemID:projectPath:)` and `records(from:to:)` read on.
    private static func withinRetention(_ records: [GroomingRecord]) -> [GroomingRecord] {
        var excess = records.count - retentionLimit
        guard excess > 0 else { return records }
        var kept: [GroomingRecord] = []
        kept.reserveCapacity(records.count - excess)
        for record in records {
            if excess > 0, record.event != .released {
                excess -= 1
                continue
            }
            kept.append(record)
        }
        return kept
    }

    /// A check refused an item at pickup.
    package func recordCheckFailure(itemID: String, projectPath: String, projectName: String,
                            check: String, reason: String, at: Date = Date()) {
        append(GroomingRecord(at: at, projectPath: projectPath, projectName: projectName,
                              itemID: itemID, event: .checkFailed, check: check, reason: reason))
    }

    /// An item was filed. `ready` distinguishes a groomed, runnable filing from a
    /// draft — the numerator of the rate this whole ledger exists to support.
    package func recordFiled(itemID: String, projectPath: String, projectName: String,
                     ready: Bool, at: Date = Date()) {
        append(GroomingRecord(at: at, projectPath: projectPath, projectName: projectName,
                              itemID: itemID, event: ready ? .filedReady : .filedDraft))
    }

    /// A human lifted the retry ceiling's refusal on an item.
    ///
    /// `reason` says who did it and why, in words — the release's whole job is to
    /// make "why did this item run again" answerable months later, and a bare
    /// timestamp answers only "when".
    package func recordRelease(itemID: String, projectPath: String, projectName: String,
                       reason: String, at: Date = Date()) {
        append(GroomingRecord(at: at, projectPath: projectPath, projectName: projectName,
                              itemID: itemID, event: .released,
                              check: GroomingRecord.Check.retryCeiling, reason: reason))
    }

    // MARK: - Queries

    /// Records in a window, oldest first. What the report reads — never the whole
    /// file.
    package func records(from start: Date, to end: Date) -> [GroomingRecord] {
        records.filter { $0.at >= start && $0.at <= end }
    }

    /// When this item was last released, or nil if it never was — what
    /// `RetryCeiling` measures its attempts from.
    ///
    /// Latest rather than first: releasing an item that was retired again after
    /// an earlier release has to clear the *later* attempts too, or the second
    /// release would do nothing. Paths are compared canonically, like the
    /// ceiling's own attribution — the ledger is portfolio-wide and item ids are
    /// only unique within a project.
    package func latestRelease(itemID: String, projectPath: String) -> Date? {
        let canonical = KiteloopProject.canonicalPath(projectPath)
        return records.last {
            $0.event == .released && $0.itemID == itemID
                && KiteloopProject.canonicalPath($0.projectPath) == canonical
        }?.at
    }

    // MARK: - File

    /// A write that fails is counted and named. The record stays in `records`, so
    /// the live view is unaffected — but it is not on disk, and nothing else will
    /// notice: the next write for this ledger is an append of its own, not a retry
    /// of this one.
    private func appendLine(_ record: GroomingRecord) {
        guard let line = Self.encode(record) else { return }
        do {
            // Through `AtomicFileWriter.append`, which starts a new line first when
            // the ledger doesn't end in one. A plain seek-to-end writes this record
            // onto the remnant of one a kill cut short, and the pair decodes as
            // neither — so a release, which is what lets `RetryCeiling` start a
            // retired item again, would be lost to the crash that happened before
            // it and the item would come back retired with nothing in the file to
            // say why.
            try AtomicFileWriter.append(Data(line.utf8), to: url)
        } catch {
            failedWriteCount += 1
            groomingLedgerLog.error("Failed to write grooming record \(record.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Rewrites the file from `records` — only after a trim, which is rare.
    ///
    /// The lines nobody could decode go back at the end, verbatim, for the same
    /// reason `RunRecordStore.rewrite()` puts its own back: this rewrite is the
    /// only thing that would ever erase them, and it would do it on the strength
    /// of a decoder that had already admitted it could not read them. An
    /// unreadable line is still somebody's history — and here it can be the
    /// release that explains why a retired item was allowed to run again.
    ///
    /// Rare, but it replaces the whole ledger, so it goes through
    /// `AtomicFileWriter` for the same reason `RunRecordStore.rewrite()` does:
    /// `Data.write(options: .atomic)` renames a temp file into place without
    /// flushing it, and an unclean shutdown just after one can leave the ledger
    /// zero-length — taking with it the releases the trim went out of its way to
    /// keep.
    private func rewrite() {
        let body = records.compactMap { Self.encode($0) }.joined()
            + undecodableLines.map { $0 + "\n" }.joined()
        do {
            try AtomicFileWriter.write(Data(body.utf8), to: url)
        } catch {
            failedWriteCount += 1
            groomingLedgerLog.error("Failed to rewrite the grooming ledger holding \(self.records.count, privacy: .public) record(s): \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func encode(_ record: GroomingRecord) -> String? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(record),
              let line = String(data: data, encoding: .utf8) else {
            groomingLedgerLog.error("Failed to encode grooming record")
            return nil
        }
        return line + "\n"
    }

    /// Loads the file under the same retention rule the trim applies, so a
    /// relaunch keeps every release the trim went out of its way to keep.
    ///
    /// A line the decoder refuses costs neither the records around it nor itself:
    /// it is set aside and handed back so `rewrite()` can write it out again, and
    /// counted so a ledger that lost a line is distinguishable from a whole one.
    /// Logged once per load rather than once per line — a kill mid-append
    /// truncates the newest line, and a truncated tail should be one error naming
    /// the ledger, not a page of them. Blank lines are not lines:
    /// `split(separator:)` drops them before anything is asked to decode them.
    ///
    /// The file is split as bytes, not read as one string: a kill partway through
    /// appending a record with a multi-byte character in it leaves bytes that are
    /// not valid UTF-8, and a whole-file string read failed on them — the ledger
    /// loaded empty, every release gone and nothing held for `rewrite()` to put
    /// back. Such a line is now held like any other the decoder refuses, lossily:
    /// the bad bytes come back as replacement characters, as `NotificationStore`
    /// holds them.
    private static func load(from url: URL) -> (records: [GroomingRecord], undecodable: [String]) {
        guard let content = try? Data(contentsOf: url) else { return ([], []) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var out: [GroomingRecord] = []
        var undecodable: [String] = []
        for line in content.split(separator: UInt8(ascii: "\n")) {
            guard let record = try? decoder.decode(GroomingRecord.self, from: line) else {
                undecodable.append(String(decoding: line, as: UTF8.self))
                continue
            }
            out.append(record)
        }
        if !undecodable.isEmpty {
            groomingLedgerLog.error("""
                \(undecodable.count, privacy: .public) line(s) in \
                \(url.lastPathComponent, privacy: .public) could not be decoded — kept \
                verbatim, so a trim cannot erase them, but nothing measured over this \
                ledger counts them
                """)
        }
        return (withinRetention(out), undecodable)
    }
}
