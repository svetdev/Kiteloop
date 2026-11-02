import Foundation

package actor WorkflowCheckpointStore {
    private let baseURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var lastPruneAt: Date?

    /// Fractional seconds are required: a workflow's start and first transition
    /// checkpoints routinely land in the same wall-clock second, and
    /// latestCheckpoint() must not tie-break to the stale one.
    ///
    /// ISO8601DateFormatter isn't Sendable, so each store owns its formatters
    /// rather than sharing a static one across concurrency domains.
    private static func makeFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    package init(baseURL: URL) {
        self.baseURL = baseURL

        let encodeFormatter = Self.makeFormatter()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, enc in
            var container = enc.singleValueContainer()
            try container.encode(encodeFormatter.string(from: date))
        }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder

        let decodeFormatter = Self.makeFormatter()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { dec in
            let container = try dec.singleValueContainer()
            let string = try container.decode(String.self)
            guard let date = decodeFormatter.date(from: string) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Unrecognized ISO8601 date: \(string)"
                )
            }
            return date
        }
        self.decoder = decoder
    }

    private func executionDir(_ executionID: String) -> URL {
        baseURL.appending(path: executionID)
    }

    private func checkpointURL(executionID: String, checkpointID: String) -> URL {
        executionDir(executionID).appending(path: "\(checkpointID).checkpoint.json")
    }

    /// Writes the checkpoint through `AtomicFileWriter`, so what is on disk
    /// afterwards is either the previous checkpoint or the complete new one.
    ///
    /// The hand-rolled sequence this replaces — temp sibling, `removeItem` the
    /// old file, `moveItem` the new one into its place — left nothing at all at
    /// the checkpoint path between the remove and the move, and `.atomic` renames
    /// without ever flushing, so the name could land while the bytes were still
    /// in the page cache. A resume after an unclean shutdown then had a missing
    /// or truncated file where its checkpoint should be. `rename(2)` replaces an
    /// existing file in place, so no removal is needed at all.
    package func write(_ checkpoint: WorkflowCheckpoint, now: Date = Date()) throws {
        let data = try encoder.encode(checkpoint)
        let finalURL = checkpointURL(executionID: checkpoint.executionID, checkpointID: checkpoint.id)
        try AtomicFileWriter.write(data, to: finalURL)
        pruneIfDue(now: now)
    }

    package func load(executionID: String, checkpointID: String) throws -> WorkflowCheckpoint? {
        let url = checkpointURL(executionID: executionID, checkpointID: checkpointID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try decoder.decode(WorkflowCheckpoint.self, from: data)
    }

    /// The checkpoint written last for this execution.
    ///
    /// Ordered by `checkpointedAt`, then by the file's modification date, then
    /// by filename. The stamp alone is not enough to say which came last: it is
    /// encoded to milliseconds, and a workflow's start and first transition
    /// routinely land in the same one (see `makeFormatter()`), so on an equal
    /// stamp the answer used to be whichever file the directory enumerator
    /// happened to yield first — which is what a resume then resumed from. The
    /// file's modification date has sub-millisecond resolution and `write(_:)`
    /// puts each checkpoint on disk as it is taken, so the later write is the
    /// later mtime; the filename breaks any remaining tie so that repeated
    /// calls over one directory agree rather than being merely usually right.
    package func latestCheckpoint(executionID: String) throws -> WorkflowCheckpoint? {
        let dir = executionDir(executionID)
        guard FileManager.default.fileExists(atPath: dir.path) else { return nil }

        let contents = try FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )
        let checkpointFiles = contents.filter { $0.pathExtension == "json" && $0.lastPathComponent.contains(".checkpoint.") }

        var candidates: [(checkpoint: WorkflowCheckpoint, modified: Date, name: String)] = []
        for file in checkpointFiles {
            guard let data = try? Data(contentsOf: file),
                  let cp = try? decoder.decode(WorkflowCheckpoint.self, from: data) else { continue }
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            candidates.append((cp, modified, file.lastPathComponent))
        }

        return candidates.max { a, b in
            if a.checkpoint.checkpointedAt != b.checkpoint.checkpointedAt {
                return a.checkpoint.checkpointedAt < b.checkpoint.checkpointedAt
            }
            if a.modified != b.modified { return a.modified < b.modified }
            return a.name < b.name
        }?.checkpoint
    }

    /// Executions that could genuinely be continued — the ones the resume prompt
    /// offers. An execution parked on a terminal node is excluded even when its
    /// status still reads `running`: autopilot leaves a run sitting on `blocked`
    /// or `done` with nothing after it, and offering hundreds of those is what
    /// made the prompt unanswerable.
    package func listIncompleteExecutions() throws -> [WorkflowCheckpoint] {
        guard FileManager.default.fileExists(atPath: baseURL.path) else { return [] }

        let execDirs = try FileManager.default.contentsOfDirectory(at: baseURL, includingPropertiesForKeys: [.isDirectoryKey])

        var results: [WorkflowCheckpoint] = []
        for dir in execDirs {
            guard let latest = try? latestCheckpoint(executionID: dir.lastPathComponent) else { continue }
            if !latest.isSettled {
                results.append(latest)
            }
        }
        return results
    }

    /// Deletes the checkpoint directories of executions that can never be
    /// resumed and settled more than `retention` ago, returning how many went.
    ///
    /// Resume is the only reader checkpoints have, and it offers exactly the
    /// executions that are *not* settled — so no execution this removes could
    /// have been offered. A directory whose checkpoints cannot be read is left
    /// alone: what cannot be evaluated is not deleted.
    ///
    /// Nothing used to prune, which is how one project reached 495 execution
    /// directories holding 1,506 checkpoint files.
    @discardableResult
    package func pruneSettledExecutions(retention: TimeInterval = Defaults.settledRetention, now: Date = Date()) throws -> Int {
        guard FileManager.default.fileExists(atPath: baseURL.path) else { return 0 }

        let execDirs = try FileManager.default.contentsOfDirectory(at: baseURL, includingPropertiesForKeys: [.isDirectoryKey])
        let cutoff = now.addingTimeInterval(-retention)

        var removed = 0
        for dir in execDirs {
            let executionID = dir.lastPathComponent
            guard let latest = try? latestCheckpoint(executionID: executionID) else { continue }
            guard latest.isSettled, latest.checkpointedAt < cutoff else { continue }
            guard (try? deleteCheckpoints(executionID: executionID)) != nil else { continue }
            removed += 1
        }
        return removed
    }

    package enum Defaults {
        /// How long a settled execution's checkpoints are kept. Long enough to
        /// look at a run that finished while the app was closed, short enough
        /// that a busy project does not accumulate thousands of dead files.
        package static let settledRetention: TimeInterval = 24 * 60 * 60

        /// How often a write is allowed to sweep for settled executions. Pruning
        /// walks the whole checkpoints directory, so a busy run writing many
        /// checkpoints must not walk it on every single one.
        package static let pruneInterval: TimeInterval = 60 * 60
    }

    /// Sweeps settled executions on the first write after the store starts, and
    /// then at most once per `Defaults.pruneInterval` — so a project left
    /// open for a day still prunes, without every write paying for the walk.
    /// Errors are swallowed: a failed sweep must never cost the checkpoint that
    /// was just written.
    private func pruneIfDue(now: Date) {
        if let lastPruneAt, now.timeIntervalSince(lastPruneAt) < Defaults.pruneInterval { return }
        lastPruneAt = now
        _ = try? pruneSettledExecutions(now: now)
    }

    package func deleteCheckpoints(executionID: String) throws {
        let dir = executionDir(executionID)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }
}
