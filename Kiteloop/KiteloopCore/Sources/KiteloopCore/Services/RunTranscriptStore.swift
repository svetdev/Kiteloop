import Foundation
import os.log

private let transcriptLog = Logger(subsystem: "ai.kasatkin.kiteloop", category: "run-transcript")

/// What a run's agents actually did, kept per *run* instead of per agent.
///
/// An agent used to keep one rolling transcript: `.kiteloop/sessions/<agentID>/`
/// held the current chat and every turn overwrote the last. Measured 2026-08-09,
/// that left 6 session files on disk against 658 runs in the metrics ledger —
/// the evidence for nearly every run was gone by the time anyone asked for it.
/// Worse, nothing on a session record said which run produced it, so even a
/// surviving file could not answer "what did the worker do during run X".
///
/// Both halves are fixed here the same way turn spans were: the run's
/// `executionID` and the node's `role` are stamped at *write* time, from the
/// workflow reservation that already owns the turn, and the file is keyed by the
/// run rather than by the agent. A turn with no owning run — a human chatting to
/// an agent — is not recorded here at all; it stays in the chat session, which is
/// where someone would look for it.
///
/// Layout, one directory per run:
///
///     .kiteloop/transcripts/<executionID>/worker.jsonl
///                                        /reviewer.jsonl
///                                        /pruned.json     ← after retention
///
/// **Retention is seven days.** A week is long enough to investigate anything
/// worth investigating and bounds the cost without needing a count-based policy
/// that behaves differently on a busy week than on a quiet one. Pruning replaces
/// a run's records with a tombstone rather than deleting the directory, because
/// "aged out" and "never existed" mean opposite things about a run and a caller
/// that cannot tell them apart will read the first as the second. The tombstone
/// therefore goes down *before* the records it stands in for come off, and a run
/// whose marker could not be written keeps its records and is reported as not
/// pruned: losing both is exactly the misreading the tombstone exists to prevent.
///
/// **Volume is bounded per record, not per kind.** The item that asked for this
/// expected `thinking` to be the payload worth shedding first. Measured against
/// the surviving session files (303 records, 479 KB, 2026-08-09) it is not:
///
///     toolResult   111 records   74.9% of bytes   median 1.3 KB   max 35.7 KB
///     toolCall     111 records   19.1%            median 0.5 KB   max 20.1 KB
///     text          20 records    3.8%            median 0.3 KB   max  4.3 KB
///     thinking      61 records    2.2%            median 0.2 KB   max  0.2 KB
///
/// Thinking is 2.2% of the bytes and arrives mostly empty — the CLI redacts it
/// unless it is switched on — while tool results are three quarters of the
/// volume. So nothing is dropped by kind: every record is clipped to
/// `maxRecordBytes`, keeping the head *and* the tail so a build log keeps both
/// the command and the error it ended on, and thinking gets the tightest cap of
/// all — it remains the first thing to shed if size ever becomes the problem.
/// Images are the one payload replaced outright: a base64 screenshot is megabytes
/// and says nothing in a text record.
///
/// **Disk growth, measured.** A run's model-written records (tool calls, text,
/// thinking) are 25.1% of transcript bytes in that sample, and a run wrote 5,527
/// output tokens on average across the 292 attributed executions in the trace
/// files for 4, 8 and 9 August 2026 — about 22 KB, so ~88 KB of transcript per
/// run, or **~72 KB after clipping** (the caps take 18% off that sample). The
/// heaviest seven days on record — 3–9 August 2026, 649 runs in the metrics
/// ledger — would therefore hold **~50 MB**. Retention holds it there rather than
/// letting it accumulate: a heavy week displaces the week before it. Tombstones
/// are the one part that grows without bound, at ~200 bytes a run — ~130 KB a
/// week, ~7 MB a year at that rate. `usage()` reports the real figure, so the
/// estimate can be checked rather than trusted.
package actor RunTranscriptStore {

    // MARK: - Types

    /// One line of a run's transcript: the message an agent produced, plus the
    /// run and role that produced it. The stamps are the point — a record that
    /// carries the message alone is what the old session files already held.
    package struct Record: Codable, Sendable {
        /// The workflow execution this record belongs to.
        package let executionID: String
        /// The workflow node that produced it: `worker`, `reviewer`, …
        package let role: String
        package let agentID: String
        package let recordedAt: Date
        package let message: Message
    
        /// The memberwise init, spelled out: a `package` type's synthesised one is
        /// internal to the package, and the app constructs this.
        package init(executionID: String, role: String, agentID: String, recordedAt: Date, message: Message) {
            self.executionID = executionID
            self.role = role
            self.agentID = agentID
            self.recordedAt = recordedAt
            self.message = message
        }
    }

    /// Whether a run's transcript is on disk, was pruned, or never existed.
    /// `absent` is deliberately narrow: it means nothing was ever written under
    /// this execution id, not "we no longer have it".
    package enum Status: Equatable, Sendable {
        case present(recordCount: Int, byteCount: Int, lastRecordAt: Date?)
        case pruned(at: Date, retentionDays: Int)
        case absent
    }

    /// What a prune pass removed, so a sweep can be logged rather than inferred —
    /// and what it could not, so a sweep that left work behind says so instead of
    /// reading as one that had nothing to do.
    package struct PruneReport: Equatable, Sendable {
        package var runsPruned: Int = 0
        package var recordsPruned: Int = 0
        package var bytesReclaimed: Int = 0
        /// Aged-out runs left intact because their tombstone could not be
        /// written. They are not counted in any of the three above: nothing was
        /// removed and nothing was reclaimed.
        package var runsNotPruned: Int = 0
    
        /// The memberwise init, spelled out: a `package` type's synthesised one is
        /// internal to the package, and the app constructs this.
        package init(runsPruned: Int = 0, recordsPruned: Int = 0, bytesReclaimed: Int = 0, runsNotPruned: Int = 0) {
            self.runsPruned = runsPruned
            self.recordsPruned = recordsPruned
            self.bytesReclaimed = bytesReclaimed
            self.runsNotPruned = runsNotPruned
        }
    }

    /// Bytes on disk, split by what they are: live transcripts are what the
    /// retention window bounds, tombstones are what outlives it.
    package struct Usage: Equatable, Sendable {
        package var runs: Int = 0
        package var bytes: Int = 0
        package var prunedRuns: Int = 0
        package var tombstoneBytes: Int = 0
    
        /// The memberwise init, spelled out: a `package` type's synthesised one is
        /// internal to the package, and the app constructs this.
        package init(runs: Int = 0, bytes: Int = 0, prunedRuns: Int = 0, tombstoneBytes: Int = 0) {
            self.runs = runs
            self.bytes = bytes
            self.prunedRuns = prunedRuns
            self.tombstoneBytes = tombstoneBytes
        }
    }

    package struct Limits: Sendable {
        /// Seven days. See the type's note.
        package var retention: TimeInterval = 7 * 24 * 60 * 60
        package var maxRecordBytes = 8 * 1024
        /// Tightest cap of the lot — thinking is the least reliable signal per
        /// byte, so it sheds first.
        package var maxThinkingBytes = 1024
        /// How often a write pass is allowed to sweep for expired runs. Pruning
        /// walks the whole directory, so a run writing hundreds of records must
        /// not walk it hundreds of times.
        package var pruneInterval: TimeInterval = 60 * 60
    }

    // MARK: - State

    private let baseURL: URL
    private let limits: Limits
    private var lastPruneAt: Date?

    /// The retention window in whole days, the way a tombstone records it — read
    /// by the sweep that stamps one and by the reader that has to stand in for
    /// one it cannot decode, so the two cannot come to say different things.
    private var retentionDays: Int { Int((limits.retention / 86_400).rounded()) }

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    package init(baseURL: URL, limits: Limits = Limits()) {
        self.baseURL = baseURL
        self.limits = limits
    }

    // MARK: - Writing

    /// Appends records to their runs' transcripts. Never throws and never
    /// reports failure to the caller: losing a record is a nuisance, stalling or
    /// failing the run that produced it is worse. Failures are logged.
    package func append(_ records: [Record], now: Date = Date()) {
        guard !records.isEmpty else { return }
        pruneIfDue(now: now)

        // Grouped so a burst of records for one run is one open/append/close
        // rather than one per record. `Dictionary(grouping:)` keeps each group in
        // arrival order, which is the order the transcript needs.
        let byFile = Dictionary(grouping: records) {
            FileKey(executionID: $0.executionID, role: $0.role)
        }
        for (key, group) in byFile {
            write(group, for: key)
        }
    }

    private func write(_ records: [Record], for key: FileKey) {
        var payload = Data()
        for record in records {
            var message = record.message
            message.content = clip(message.content)
            let bounded = Record(
                executionID: record.executionID,
                role: record.role,
                agentID: record.agentID,
                recordedAt: record.recordedAt,
                message: message
            )
            guard let line = try? encoder.encode(bounded) else { continue }
            payload.append(line)
            payload.append(0x0A)
        }
        guard !payload.isEmpty else { return }

        let directory = runDirectory(for: key.executionID)
        let fileURL = directory.appending(path: "\(sanitized(key.role)).jsonl")
        do {
            // A run that was pruned and then wrote again is live again; the
            // tombstone would otherwise claim its records are gone while they sit
            // in the same directory.
            try? FileManager.default.removeItem(at: tombstoneURL(for: key.executionID))

            // Through `AtomicFileWriter.append`, which makes the run's directory
            // and the role's file when they aren't there yet and starts a new line
            // first when the file doesn't end in one. A plain seek-to-end writes
            // this batch onto the remnant of a record a kill cut short, and the
            // pair decodes as neither — so the first record written after the
            // crash is lost from the only evidence of what the agent did.
            try AtomicFileWriter.append(payload, to: fileURL)
        } catch {
            transcriptLog.error("""
                Failed to write transcript for \(key.executionID, privacy: .public)/\
                \(key.role, privacy: .public): \(error.localizedDescription, privacy: .public)
                """)
        }
    }

    // MARK: - Reading

    /// Whether the run's transcript is on disk, pruned, or was never written.
    package func status(of executionID: String) -> Status {
        let directory = runDirectory(for: executionID)
        if let mark = pruneMark(for: executionID) {
            return .pruned(at: mark.prunedAt, retentionDays: mark.retentionDays)
        }
        let files = transcriptFiles(in: directory)
        guard !files.isEmpty else { return .absent }

        var count = 0
        var bytes = 0
        var last: Date?
        for file in files {
            let records = decodeRecords(at: file)
            count += records.count
            bytes += byteCount(of: file)
            if let newest = records.map(\.recordedAt).max(), newest > (last ?? .distantPast) {
                last = newest
            }
        }
        return .present(recordCount: count, byteCount: bytes, lastRecordAt: last)
    }

    /// A run's records in the order they happened, optionally for one role only.
    package func records(of executionID: String, role: String? = nil) -> [Record] {
        let directory = runDirectory(for: executionID)
        var all: [Record] = []
        for file in transcriptFiles(in: directory) {
            if let role, file.deletingPathExtension().lastPathComponent != sanitized(role) { continue }
            all.append(contentsOf: decodeRecords(at: file))
        }
        return all.sorted { $0.recordedAt < $1.recordedAt }
    }

    /// Bytes the transcripts occupy right now — the figure the retention window
    /// exists to bound, and the one to check it against.
    package func usage() -> Usage {
        var usage = Usage()
        for directory in runDirectories() {
            if let tombstoneBytes = tombstoneBytes(in: directory) {
                usage.prunedRuns += 1
                usage.tombstoneBytes += tombstoneBytes
                continue
            }
            let files = transcriptFiles(in: directory)
            guard !files.isEmpty else { continue }
            usage.runs += 1
            usage.bytes += files.reduce(0) { $0 + byteCount(of: $1) }
        }
        return usage
    }

    // MARK: - Pruning

    /// Replaces every run older than the retention window with a tombstone.
    @discardableResult
    package func prune(now: Date = Date()) -> PruneReport {
        lastPruneAt = now
        let cutoff = now.addingTimeInterval(-limits.retention)
        var report = PruneReport()

        for directory in runDirectories() {
            let files = transcriptFiles(in: directory)
            guard !files.isEmpty else { continue }
            guard let newest = files.compactMap({ modifiedAt(of: $0) }).max(), newest < cutoff else { continue }

            var records = 0
            var bytes = 0
            for file in files {
                records += decodeRecords(at: file).count
                bytes += byteCount(of: file)
            }

            // The tombstone lands before the records it stands in for come off.
            // Removing them first and then failing to write it leaves the run with
            // neither, which reads back as `.absent` — "never existed" rather than
            // "aged out", the one confusion this whole scheme exists to prevent.
            do {
                try writeTombstone(
                    Tombstone(
                        executionID: directory.lastPathComponent,
                        prunedAt: now,
                        retentionDays: retentionDays,
                        lastRecordAt: newest,
                        recordCount: records,
                        byteCount: bytes
                    ),
                    in: directory
                )
            } catch {
                transcriptLog.error("""
                    Left transcript for \(directory.lastPathComponent, privacy: .public) in place: \
                    its tombstone could not be written: \
                    \(error.localizedDescription, privacy: .public)
                    """)
                report.runsNotPruned += 1
                continue
            }

            for file in files {
                try? FileManager.default.removeItem(at: file)
            }
            report.runsPruned += 1
            report.recordsPruned += records
            report.bytesReclaimed += bytes
        }

        if report.runsPruned > 0 {
            transcriptLog.info("""
                Pruned \(report.runsPruned, privacy: .public) run transcript(s), \
                \(report.bytesReclaimed, privacy: .public) bytes
                """)
        }
        if report.runsNotPruned > 0 {
            transcriptLog.error("""
                Left \(report.runsNotPruned, privacy: .public) aged-out run transcript(s) in place: \
                no tombstone could be written for them
                """)
        }
        return report
    }

    /// Sweeps on the first write and then at most once an hour, so retention is
    /// enforced by the app running rather than by a timer that has to be
    /// remembered, without a long run paying for the walk on every record.
    private func pruneIfDue(now: Date) {
        if let lastPruneAt, now.timeIntervalSince(lastPruneAt) < limits.pruneInterval { return }
        prune(now: now)
    }

    // MARK: - Clipping

    private func clip(_ content: Message.Content) -> Message.Content {
        switch content {
        case .text(let t):
            return .text(Self.clip(t, to: limits.maxRecordBytes))
        case .thinking(let t):
            return .thinking(Self.clip(t, to: limits.maxThinkingBytes))
        case .error(let t):
            return .error(Self.clip(t, to: limits.maxRecordBytes))
        case .toolCall(let call):
            return .toolCall(Message.ToolCall(
                id: call.id,
                name: call.name,
                input: Self.clip(call.input, to: limits.maxRecordBytes),
                output: call.output.map { Self.clip($0, to: limits.maxRecordBytes) },
                isCollapsed: call.isCollapsed
            ))
        case .toolResult(let result):
            return .toolResult(Message.ToolResult(
                id: result.id,
                toolCallID: result.toolCallID,
                output: Self.clip(result.output, to: limits.maxRecordBytes)
            ))
        case .image(let data):
            return .text("[image omitted — \(data.count) bytes]")
        default:
            return content
        }
    }

    /// Keeps the head and the tail either side of an elision marker. A build log
    /// puts the command at the top and the failure at the bottom, and a head-only
    /// clip throws away the half that says what went wrong.
    package static func clip(_ text: String, to cap: Int) -> String {
        guard cap > 0, text.utf8.count > cap else { return text }
        let headBytes = cap * 3 / 5
        let head = prefix(of: text, bytes: headBytes)
        let tail = suffix(of: text, bytes: cap - headBytes)
        let elided = text.utf8.count - head.utf8.count - tail.utf8.count
        guard elided > 0 else { return text }
        return "\(head)\n… \(elided) bytes elided …\n\(tail)"
    }

    /// Byte-bounded but character-aligned: cutting mid-scalar would produce a
    /// record that no longer decodes as the text it came from.
    private static func prefix(of text: String, bytes limit: Int) -> String {
        var result = ""
        var used = 0
        for character in text {
            let size = String(character).utf8.count
            if used + size > limit { break }
            result.append(character)
            used += size
        }
        return result
    }

    private static func suffix(of text: String, bytes limit: Int) -> String {
        var result = ""
        var used = 0
        for character in text.reversed() {
            let size = String(character).utf8.count
            if used + size > limit { break }
            result.insert(character, at: result.startIndex)
            used += size
        }
        return result
    }

    // MARK: - Layout

    private struct FileKey: Hashable {
        let executionID: String
        let role: String
    }

    /// What a pruned run leaves behind: enough to say the transcript existed,
    /// how big it was, and when it aged out.
    private struct Tombstone: Codable {
        let executionID: String
        let prunedAt: Date
        let retentionDays: Int
        let lastRecordAt: Date
        let recordCount: Int
        let byteCount: Int
    }

    private func runDirectory(for executionID: String) -> URL {
        baseURL.appending(path: sanitized(executionID))
    }

    private func tombstoneURL(for executionID: String) -> URL {
        runDirectory(for: executionID).appending(path: "pruned.json")
    }

    /// Execution ids and node ids reach here from workflow graphs, which are
    /// user-authored — a `/` or a `..` in one would otherwise write outside the
    /// transcripts directory.
    private func sanitized(_ component: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let mapped = String(component.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        let trimmed = mapped.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return trimmed.isEmpty ? "unnamed" : trimmed
    }

    private func runDirectories() -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: baseURL, includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        return contents.filter(\.hasDirectoryPath)
    }

    private func transcriptFiles(in directory: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        return contents.filter { $0.pathExtension == "jsonl" }.sorted { $0.path < $1.path }
    }

    private func decodeRecords(at url: URL) -> [Record] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        // Each line on its own bytes: one invalid byte costs only its line.
        return data.split(separator: UInt8(ascii: "\n")).compactMap {
            try? decoder.decode(Record.self, from: Data($0))
        }
    }

    /// Throws rather than swallowing: the caller removes a run's records only once
    /// this has landed, so "it didn't" has to be something it can see.
    private func writeTombstone(_ tombstone: Tombstone, in directory: URL) throws {
        let data = try encoder.encode(tombstone)
        try data.write(to: directory.appending(path: "pruned.json"), options: .atomic)
    }

    /// When a run aged out and under what window, or `nil` when it has no
    /// tombstone at all.
    ///
    /// A tombstone whose bytes will not decode is still a tombstone. It is on
    /// disk only because `prune()` put it there, and the records it stands in
    /// for came off immediately afterwards — so reading unreadable bytes as "no
    /// tombstone" hands the caller `.absent`, "nothing was ever written under
    /// this execution id", which is the one confusion this whole scheme exists
    /// to prevent. It also made the two readers disagree about the same run:
    /// `usage()` counts it in `prunedRuns` on the file being there at all.
    /// Whether the file is there is therefore what decides here too, and only
    /// the *contents* of the answer fall back — to when the file was last
    /// written and the window this store is configured with, which is the pair
    /// `prune()` would have stamped into it. A directory named `pruned.json` is
    /// not a tombstone but the obstruction that stopped one being written, and
    /// the run it blocked still holds its records: `prune()` leaves them where
    /// they are, and they are what the run reads as.
    ///
    /// The unreadable file is left exactly where it is, the choice
    /// `RunRecordStore.rewrite()` makes for a line it could not decode: an
    /// unreadable record is still somebody's history.
    private func pruneMark(for executionID: String) -> (prunedAt: Date, retentionDays: Int)? {
        let url = tombstoneURL(for: executionID)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false),
                                             isDirectory: &isDirectory),
              !isDirectory.boolValue else { return nil }
        if let data = try? Data(contentsOf: url),
           let tombstone = try? decoder.decode(Tombstone.self, from: data) {
            return (tombstone.prunedAt, tombstone.retentionDays)
        }
        // A file with no modification date is not something a filesystem
        // produces; `.distantPast` is the honest reading if one ever appears —
        // pruning only happens after the window, so "some time well before now"
        // is true of every tombstone, while a stamp of *now* would claim a sweep
        // that is not happening.
        return (modifiedAt(of: url) ?? .distantPast, retentionDays)
    }

    private func tombstoneBytes(in directory: URL) -> Int? {
        let url = directory.appending(path: "pruned.json")
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return nil }
        return byteCount(of: url)
    }

    private func byteCount(of url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    private func modifiedAt(of url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}
