import Foundation
import KiteloopCore

protocol TraceStoring: Sendable {
    func loadSpans(for date: Date) async -> [TraceSpan]
    func loadSpans(for agentID: String) async -> [TraceSpan]
    func allSessions() async -> [TraceSession]
}

struct TraceSession: Identifiable, Sendable {
    let id: String
    let agentID: String
    let date: Date
    let spanCount: Int
    let totalCost: Double
    let duration: TimeInterval
}

actor TraceStore: TraceStoring {
    /// What a day file looked like when it was last read. Size *and* modification
    /// date, because either one alone can miss a rewrite: a file edited in place
    /// keeps its size, and two appends inside one timestamp tick keep its mtime.
    private struct FileStamp: Equatable {
        let size: Int
        let modified: Date
    }

    /// A day file's decoded contents, held against the stamp they were decoded
    /// from. The two decoders disagree about what a line is, so `TraceSpan` and
    /// `Span` readings of the same file live in separate caches rather than
    /// sharing an entry.
    private struct CachedFile<Decoded> {
        let stamp: FileStamp
        let decoded: [Decoded]
    }

    private let tracesURL: URL
    private let decoder: JSONDecoder
    private let spanDecoder: JSONDecoder
    private var traceSpanCache: [String: CachedFile<TraceSpan>] = [:]
    private var otelSpanCache: [String: CachedFile<Span>] = [:]
    /// How many day files a load has actually read off disk and decoded. Exposed
    /// so a caller — and a test — can see a read that did *not* happen, as
    /// `RunRecordStore.undecodableLineCount` is: the whole point of the cache is
    /// that the autopilot's ~16s cost sample stops re-decoding every trace the
    /// project has ever written, and nothing else about a load says so.
    private(set) var filesRead = 0

    init(tracesURL: URL) {
        self.tracesURL = tracesURL
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
        self.spanDecoder = JSONDecoder()
        self.spanDecoder.dateDecodingStrategy = .iso8601
    }

    /// Appends a span to the current day's trace file, creating the
    /// traces directory and file on first write.
    func append(_ span: TraceSpan) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(span),
              let line = String(data: data, encoding: .utf8) else { return }

        let fileURL = tracesURL.appending(path: "\(DayKey.string(for: span.startTime)).jsonl")

        // Through `AtomicFileWriter.append`, which makes the traces directory and
        // the day's file when they aren't there yet and starts a new line first
        // when the file doesn't end in one. A plain seek-to-end writes this span
        // onto the remnant of one a kill cut short, and the pair decodes as
        // neither — so the span recorded after the crash is missing from the
        // traces, and the turn it belonged to is unaccounted for in the cost and
        // duration read off them.
        try? AtomicFileWriter.append(Data((line + "\n").utf8), to: fileURL)

        // The writer knows exactly which file it changed, so it says so rather
        // than leaving the next load to infer it from the stamp. The stamp would
        // catch this append — it grows the file — but it is the only writer in
        // the app, and an entry it dropped itself cannot go stale.
        let file = fileURL.lastPathComponent
        traceSpanCache[file] = nil
        otelSpanCache[file] = nil
    }

    func loadSpans(for date: Date) -> [TraceSpan] {
        let dateStr = DayKey.string(for: date)

        return loadAllSpans().filter { span in
            DayKey.string(for: span.startTime) == dateStr
        }
    }

    func loadSpans(for agentID: String) -> [TraceSpan] {
        loadAllSpans().filter { $0.agentID == agentID }
    }

    func allSessions() -> [TraceSession] {
        let spans = loadAllSpans()
        let grouped = Dictionary(grouping: spans.filter { $0.type == .turn }) { $0.sessionID }

        return grouped.map { sessionID, turns in
            let firstTurn = turns.min(by: { $0.startTime < $1.startTime })!
            let totalDuration = turns.compactMap(\.duration).reduce(0, +)
            let cost = totalCost(of: turns)

            return TraceSession(
                id: sessionID,
                agentID: firstTurn.agentID,
                date: firstTurn.startTime,
                spanCount: turns.count,
                totalCost: cost,
                duration: totalDuration
            )
        }.sorted { $0.date > $1.date }
    }

    /// What a session's turns actually spent: each turn's own contribution,
    /// summed. `costUSD` is the CLI's running total for the whole session at the
    /// time of the turn, so summing it counts every earlier turn again —
    /// `costDeltaUSD` is what the turn added, and that is what is summed here.
    ///
    /// Spans written before the delta was recorded carry only the running total,
    /// and each of those already contains the ones before it, so the largest of
    /// them is counted once rather than summed. A turn with neither reading
    /// contributes nothing.
    private func totalCost(of turns: [TraceSpan]) -> Double {
        let added = turns.compactMap(\.costDeltaUSD).reduce(0, +)
        let legacyTotal = turns
            .filter { $0.costDeltaUSD == nil }
            .compactMap(\.reportedCostUSD)
            .max() ?? 0
        return added + legacyTotal
    }

    private func loadAllSpans() -> [TraceSpan] {
        scan(&traceSpanCache) { data in
            decodeLines(of: data, as: TraceSpan.self, with: decoder)
        }
    }

    // MARK: - OTel Span Loading

    func loadOTelSpans() -> [Span] {
        scan(&otelSpanCache) { data in
            decodeLines(of: data, as: Span.self, with: spanDecoder)
        }
    }

    func loadOTelSpans(for agentID: String) -> [Span] {
        loadOTelSpans().filter { $0.agentID == agentID }
    }

    // MARK: - Reading the day files

    /// Walks the traces directory in file-name order and returns everything the
    /// day files decode to, reading only the ones whose size or modification date
    /// differs from what the cache holds. Entries for files that are no longer
    /// there are dropped, so a deleted day stops contributing spans.
    ///
    /// This is what keeps a trace read proportional to what was appended since
    /// the last one rather than to everything the project has ever written:
    /// `BacklogAutopilot` samples live spend every few poll ticks, and each
    /// sample used to re-read and re-decode the whole history.
    private func scan<Decoded>(
        _ cache: inout [String: CachedFile<Decoded>],
        decode: (Data) -> [Decoded]
    ) -> [Decoded] {
        let fm = FileManager.default
        let tracesPath = tracesURL.path(percentEncoded: false)
        guard let files = try? fm.contentsOfDirectory(atPath: tracesPath) else {
            // No directory is no files: everything the cache holds is gone.
            cache.removeAll()
            return []
        }

        var present: Set<String> = []
        var decodedSpans: [Decoded] = []
        for file in files.sorted() where file.hasSuffix(".jsonl") {
            present.insert(file)
            let fileURL = tracesURL.appending(path: file)
            // Stamped before it is read, never after: a write landing between the
            // two then files the *older* stamp against the newer content, so the
            // next load sees a mismatch and reads again. Stamping afterwards
            // would file the newer stamp against content read before the write,
            // and that entry would never be reconsidered.
            let fileStamp = stamp(of: fileURL)

            if let fileStamp, let cached = cache[file], cached.stamp == fileStamp {
                decodedSpans.append(contentsOf: cached.decoded)
                continue
            }

            guard let data = try? Data(contentsOf: fileURL) else {
                cache[file] = nil
                continue
            }
            filesRead += 1

            let fresh = decode(data)
            // A file that would not stat is read every time rather than cached
            // against a stamp there is nothing to compare later.
            cache[file] = fileStamp.map { CachedFile(stamp: $0, decoded: fresh) }
            decodedSpans.append(contentsOf: fresh)
        }

        cache = cache.filter { present.contains($0.key) }
        return decodedSpans
    }

    /// Splits on the newline byte and decodes each line's bytes on their own,
    /// rather than decoding the whole file as one string first: a single
    /// multi-byte character a kill cut short would fail that, and every span the
    /// day recorded would go with it. Here a line that is not valid UTF-8 is
    /// refused by the JSON decoder and skipped like any other malformed line.
    private func decodeLines<Decoded: Decodable>(
        of data: Data,
        as type: Decoded.Type,
        with decoder: JSONDecoder
    ) -> [Decoded] {
        data.split(separator: UInt8(ascii: "\n")).compactMap { line in
            try? decoder.decode(type, from: Data(line))
        }
    }

    private func stamp(of fileURL: URL) -> FileStamp? {
        // Through `FileManager` rather than `URL.resourceValues`, which answers
        // from the URL's own cache once it has been asked — a stamp that cannot
        // go stale is the whole basis of the invalidation here.
        guard let attributes = try? FileManager.default
            .attributesOfItem(atPath: fileURL.path(percentEncoded: false)),
              let size = attributes[.size] as? Int,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        return FileStamp(size: size, modified: modified)
    }
}
