import Foundation

/// Reads the escaped-defect record — the JSONL ledger `EscapedDefectTracker`
/// appends to, one `ItemApprovalEvent` per line — into one finding per item that
/// came back after being approved.
///
/// Decodes the ledger's own JSON shape directly rather than depending on the app
/// type it mirrors: `ItemApprovalEvent` lives above the package, and this reader
/// has to run under `swift test` without it. Only the fields a finding needs are
/// declared — an extra field on the real event decodes and is ignored.
package enum EscapedDefectReader {
    private struct ReopenLine: Decodable {
        let projectPath: String
        let itemID: String
        let kind: String
        let at: Date
        let approvedAt: Date?
        let toStatus: String?
    }

    /// - Parameter projectPath: which project's reopens to read — the ledger is
    ///   shared across every project the app has open, and a finding about one
    ///   project's item is not evidence about another's.
    package static func read(_ jsonl: String, projectPath: String) -> [SignalFinding] {
        read(Data(jsonl.utf8), projectPath: projectPath)
    }

    /// The same read over the ledger's bytes, which is what a caller holding a
    /// file has: the bytes are split on the newline and each line is decoded on
    /// its own, so a line the decoder refuses costs only itself and every
    /// complete reopen before it still becomes a finding. That includes the
    /// truncation `AtomicFileWriter.append` is written to survive — a kill
    /// part-way through a multi-byte character leaves a last line that is not
    /// valid UTF-8, and decoding the file as one string used to lose the whole
    /// ledger, and so the whole pass's escaped-defect findings, to it.
    package static func read(_ jsonl: Data, projectPath: String) -> [SignalFinding] {
        findings(from: reopenLines(in: jsonl, projectPath: projectPath))
    }

    /// Every line of the ledger this project wrote, in the order it wrote them.
    private static func reopenLines(in jsonl: Data, projectPath: String) -> [ReopenLine] {
        let canonical = KiteloopProject.canonicalPath(projectPath)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return jsonl.split(separator: UInt8(ascii: "\n")).compactMap { line -> ReopenLine? in
            try? decoder.decode(ReopenLine.self, from: line)
        }.filter { KiteloopProject.canonicalPath($0.projectPath) == canonical }
    }

    private static func findings(from lines: [ReopenLine]) -> [SignalFinding] {
        let formatter = ISO8601DateFormatter()
        // Both kinds have to be in view for `MergeRetryChurn` to tell a real
        // reopen from the gate-retry loop re-approving its own bounce — only
        // the reopens survive the fold, but a `.reopened` line arrives here
        // exactly as `EscapedDefectTracker` wrote it either way.
        let moments = lines.map {
            MergeRetryChurn.Moment(key: $0.itemID, isReopen: $0.kind == "reopened", at: $0.at, payload: $0)
        }
        // A genuine reopen still isn't an escape unless it came back inside
        // the escaped-defect window of its own approval — the same call
        // `TaskMetricStore.escapedDefectRate` makes, at the same inclusive
        // boundary, so the signal and the metric agree on what escaped.
        let reopens = MergeRetryChurn.genuine(moments).filter(\.isReopen).map(\.payload).filter { reopen in
            guard let approvedAt = reopen.approvedAt else { return false }
            let elapsed = reopen.at.timeIntervalSince(approvedAt)
            return elapsed >= 0 && elapsed <= EscapedDefectWindow.standard
        }

        let byItem = Dictionary(grouping: reopens, by: \.itemID)
        return byItem.keys.sorted().compactMap { itemID in
            guard let events = byItem[itemID]?.sorted(by: { $0.at < $1.at }) else { return nil }
            let evidence = events.map { event -> String in
                var line = "reopened to \(event.toStatus ?? "ready") on \(formatter.string(from: event.at))"
                if let approvedAt = event.approvedAt {
                    line += " — approved \(formatter.string(from: approvedAt))"
                }
                return line
            }
            return SignalFinding(instrument: .escapedDefect, key: itemID, title: itemID, evidence: evidence)
        }
    }
}
