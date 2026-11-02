import KiteloopCore
import Foundation

/// One thing that happened to a backlog item, from whichever ledger recorded it.
///
/// An item's life is written down in three places and joined nowhere: its
/// `## Notes` hold what a run did to it (rejected, blocked, retired, steered),
/// `~/.kiteloop/task-approvals.jsonl` holds the gate decisions, and
/// `~/.kiteloop/grooming.jsonl` holds the filings and the pre-run refusals.
/// Answering "why has this been run five times" meant reading all three and
/// matching timestamps by eye, which is how several answers on 2026-08-09/10
/// were wrong the first time.
struct ItemStateChange: Identifiable, Equatable, Sendable {

    /// Which ledger said so. Kept on the entry rather than folded away: two
    /// records of the same event from two ledgers is itself information, and a
    /// timeline that silently merged them would hide the disagreement this whole
    /// view exists to show.
    enum Source: String, Equatable, Sendable {
        /// The item's own `## Notes`, written by whatever changed it.
        case notes
        /// `task-approvals.jsonl`, via the metric index.
        case approvals
        /// `grooming.jsonl` — filings and pre-run refusals.
        case grooming
    }

    /// What the entry is, in the few kinds worth telling apart by eye. Anything
    /// a note says that doesn't match one of these is `note` — the text is still
    /// shown verbatim, so nothing is lost by not classifying it.
    enum Kind: String, Equatable, Sendable {
        case filed
        case rejected
        case blocked
        case approved
        case reopened
        case retired
        case released
        case refused
        case note
    }

    /// How precisely the time is known. A note carries a date and no clock, so
    /// it is not pretended to have happened at midnight — the view prints a date
    /// for `day` and a time for `instant`.
    enum Precision: String, Equatable, Sendable {
        case day
        case instant
    }

    let at: Date
    let precision: Precision
    let source: Source
    let kind: Kind
    /// The reason, as whoever wrote it phrased it. Never invented: an entry with
    /// nothing said about it has nil here rather than a manufactured sentence.
    let detail: String?
    /// Distinguishes two entries that landed at the same instant from the same
    /// ledger — which happens, and would otherwise collapse a row in a `ForEach`.
    let ordinal: Int

    var id: String { "\(source.rawValue)-\(ordinal)-\(at.timeIntervalSince1970)" }
}

/// Joins an item's three ledgers into one ordered list.
///
/// Pure: it takes the notes text and the two ledgers as values, so the whole
/// join is exercised without an app, a database or a repo.
enum ItemTimeline {

    /// Every recorded change, **oldest first**.
    ///
    /// Note entries carry a date and no time, so within a day they sort before
    /// the ledger entries that do carry one. That is deliberate — a note written
    /// by the run that produced an approval is not evidence the note came second
    /// — and the view prints the precision it has rather than a clock it made up.
    static func changes(notes: String?,
                        approvals: [ItemApprovalEvent],
                        grooming: [GroomingRecord]) -> [ItemStateChange] {
        var out = noteChanges(notes)
        out.append(contentsOf: approvalChanges(approvals))
        out.append(contentsOf: groomingChanges(grooming))
        // Stable within a timestamp: the source order above, then the ordinal,
        // which is the order each ledger itself recorded them in.
        return out.enumerated()
            .sorted { lhs, rhs in
                lhs.element.at == rhs.element.at
                    ? lhs.offset < rhs.offset
                    : lhs.element.at < rhs.element.at
            }
            .map(\.element)
    }

    // MARK: - Notes

    /// The `## Notes` section, parsed into one entry per dated line.
    ///
    /// The section is written newest-first (`BacklogViewModel.appendNote`
    /// inserts directly under the heading), so file order is reversed here to
    /// put the oldest first — the same order every other ledger is read in.
    /// A line the format doesn't fit is dropped rather than dated by guesswork:
    /// hand-written prose under `## Notes` is common, and inventing a timestamp
    /// for it would put a fiction in the one place a person goes to check facts.
    static func noteChanges(_ notes: String?) -> [ItemStateChange] {
        guard let notes else { return [] }
        let entries = noteEntries(notes).reversed()
        return entries.enumerated().map { offset, entry in
            ItemStateChange(at: entry.date, precision: .day, source: .notes,
                            kind: kind(ofNote: entry.text), detail: entry.text,
                            ordinal: offset)
        }
    }

    /// One `- <date> — <text>` line and its indented continuations.
    ///
    /// Continuations are two-space indented (`BacklogViewModel
    /// .indentingContinuation`), which is what keeps a multi-line note — a
    /// refused approval's verify output — inside its list item. They are joined
    /// back onto the entry so the reason reads as it was written.
    static func noteEntries(_ notes: String) -> [(date: Date, text: String)] {
        var out: [(date: Date, text: String)] = []
        for line in notes.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("  "), !out.isEmpty, !trimmed.isEmpty, !trimmed.hasPrefix("- ") {
                out[out.count - 1].text += "\n" + trimmed
                continue
            }
            guard trimmed.hasPrefix("- ") else { continue }
            let body = String(trimmed.dropFirst(2))
            guard let parsed = split(body) else { continue }
            out.append(parsed)
        }
        return out
    }

    /// `2026-08-09 — rejected: …` → the date and the rest. Nil when the line
    /// does not open with a date this app wrote, which is every hand-written
    /// bullet.
    private static func split(_ body: String) -> (date: Date, text: String)? {
        // Both dashes: the app writes an em dash, and a hand-edited file (or a
        // copy through a plain-text tool) turns up with a hyphen.
        for separator in [" — ", " - "] {
            guard let range = body.range(of: separator) else { continue }
            let stamp = String(body[body.startIndex..<range.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            guard let date = dateFormatter.date(from: stamp) else { continue }
            let text = String(body[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            return (date, text)
        }
        return nil
    }

    /// The date format `BacklogViewModel.appendNote` writes. Fixed locale and a
    /// fixed zone: the string is a stored format, not something to be rendered
    /// in the reader's calendar.
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        return formatter
    }()

    /// Which of the few kinds a note line is. Matched against the phrases the
    /// writers actually use — `BacklogViewModel.appendRejectionNote`,
    /// `RetryCeiling.note` and `releaseNote`, `BacklogAutopilot`'s block notes —
    /// so a new writer that invents its own wording reads as `note` rather than
    /// being misfiled under one of these.
    static func kind(ofNote text: String) -> ItemStateChange.Kind {
        let lower = text.lowercased()
        if text.contains(RetryCeiling.noteMarker) { return .retired }
        if lower.hasPrefix("released for autopilot") { return .released }
        if lower.hasPrefix("rejected") { return .rejected }
        if lower.hasPrefix("blocked") { return .blocked }
        return .note
    }

    // MARK: - Ledgers

    private static func approvalChanges(_ events: [ItemApprovalEvent]) -> [ItemStateChange] {
        events.enumerated().map { offset, event in
            ItemStateChange(
                at: event.at, precision: .instant, source: .approvals,
                kind: event.kind == .approved ? .approved : .reopened,
                // A reopen says where it went; an approval has nothing to add
                // beyond the fact of it, so it says nothing rather than padding.
                detail: event.toStatus.map { "came back to \($0)" },
                ordinal: offset)
        }
    }

    private static func groomingChanges(_ records: [GroomingRecord]) -> [ItemStateChange] {
        records.enumerated().map { offset, record in
            let kind: ItemStateChange.Kind = switch record.event {
            case .filedReady, .filedDraft: .filed
            case .checkFailed: .refused
            case .released: .released
            }
            var detail: String?
            switch record.event {
            case .filedReady: detail = "filed at ready"
            case .filedDraft: detail = "filed as a draft"
            case .checkFailed, .released:
                detail = [record.check, record.reason]
                    .compactMap { $0 }
                    .joined(separator: ": ")
                if detail?.isEmpty == true { detail = nil }
            }
            return ItemStateChange(at: record.at, precision: .instant, source: .grooming,
                                   kind: kind, detail: detail, ordinal: offset)
        }
    }
}
