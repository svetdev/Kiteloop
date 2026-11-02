import Foundation

/// A short note an operator hands to a live run's worker while it is still
/// working.
///
/// An in-flight run used to be watch-only. You could read the worker's
/// transcript in the Autopilot panel and watch it misread the item or burn
/// budget down a dead end, and the only two things you could do about it were
/// cancel — losing the run — or wait — losing the money. Neither is an
/// intervention; both are ways of giving up. A note is the missing third
/// option: a sentence of advice that reaches the worker's own session without
/// killing the run.
///
/// **Delivery is at the worker's next turn boundary, not mid-turn.** That is a
/// property of the transport, not a preference. `ClaudeCodeCLIRuntime`'s stdout
/// reader finishes a session's stream on the first `result` line and drops the
/// continuation; a second user message written to stdin while a turn is in
/// flight would be answered on a turn whose events have nowhere to go, and the
/// node would already have completed. So the note is queued on the orchestrator
/// and delivered by `ChatViewModel` in the same seam `EmptyDiffHandoff` uses —
/// after the worker's turn ends, before its node completes. The worker gets a
/// full turn to act on it, in the same session, with all of its context. The
/// bar is that the note reaches the worker before its next message, and this
/// clears it.
///
/// **A note is advice, not re-scoping.** It cannot approve work, raise a cost
/// cap, change the item, or speak for the reviewer — the item's What / How /
/// Validation still govern what "done" means and still govern the review. The
/// framing in `prompt(_:)` says so to the worker directly, because a worker
/// handed a bare operator sentence mid-run will otherwise treat it as the new
/// specification.
///
/// **Every note is recorded**, in the run transcript as an operator message and
/// in the item's `## Notes` with the time it was sent. A steer that left no
/// trace would make run outcomes unattributable: the next reader of a merged
/// diff could not tell which of its decisions were the worker's.
package enum RunSteerNote {

    /// Longest note accepted. A steer is a course correction — "the fix belongs
    /// in the parser, not the view" — and something longer than this is a
    /// rewritten item, which is the thing steering deliberately is not. The
    /// limit is enforced by truncation rather than refusal so a paste never
    /// silently loses the whole note.
    package static let maxLength = 1_000

    /// The note as it will actually be used, or nil when there is nothing to
    /// send. Trims surrounding whitespace and caps the length; the body is
    /// otherwise left exactly as typed, newlines included, because a two-line
    /// steer with a path on the second line is a normal thing to write.
    package static func sanitize(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count > maxLength else { return trimmed }
        return String(trimmed.prefix(maxLength)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What the worker is handed. The operator's words are quoted as theirs, and
    /// everything around them is the boundary: this is advice, the item still
    /// governs, and if the two disagree the item wins and the worker says so
    /// rather than quietly following the note.
    ///
    /// Takes the whole batch because a turn can end with more than one note
    /// waiting — an operator typing three corrections while the worker runs a
    /// long build — and three separate turns to say three sentences would cost
    /// three turns of context for no gain.
    package static func prompt(_ notes: [String]) -> String {
        let body: String
        if notes.count == 1 {
            body = "An operator watching this run has sent you a note:\n\n"
                + quoted(notes[0])
        } else {
            body = "An operator watching this run has sent you \(notes.count) notes:\n\n"
                + notes.map(quoted).joined(separator: "\n\n")
        }
        return """
            \(body)

            This is advice from someone watching, not a change to the item. The \
            What / How / Validation you were given still define what done means, \
            and they are still what the reviewer will check you against. The note \
            cannot approve your work, raise any spending cap, or speak for the \
            reviewer. If it contradicts the item, the item wins — say so plainly \
            and carry on.

            Take it into account where it helps, and continue with the item.
            """
    }

    /// One note as a quoted block, indented so a multi-line steer stays visibly
    /// the operator's words rather than running into the framing around it.
    private static func quoted(_ note: String) -> String {
        note.components(separatedBy: "\n")
            .map { "  > \($0)" }
            .joined(separator: "\n")
    }

    /// How the note reads in the run transcript, where it renders as a system
    /// row in the worker's pane. Prefixed rather than shown bare so a reader
    /// scrolling a run can tell an operator's sentence from the worker's own
    /// prose at a glance.
    package static func transcriptLine(_ note: String) -> String {
        "Operator note to the worker: \(note)"
    }

    /// The line written to the item's `## Notes`. `BacklogViewModel.appendNote`
    /// already stamps the date, so this carries the time — a run's steers happen
    /// minutes apart and a date alone could not order them.
    package static func itemNoteLine(_ note: String, at date: Date = Date()) -> String {
        "steered \(timeFormatter.string(from: date)) — \(note)"
    }

    /// The run-log line, so a transcript read afterwards shows the steer as a
    /// step the run took rather than as an unexplained extra worker turn.
    package static func logLine(_ note: String) -> String {
        "Note sent to the worker — delivered at its next turn boundary: \(note)"
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}
