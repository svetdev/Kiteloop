import Foundation

/// The reviewer's verdict, once it carries more than a boolean.
///
/// `passed` alone makes every observation blocking by construction: a reviewer
/// that notices a misnamed variable while approving good work has two options,
/// reject the whole run over it or say nothing, and the second is the one it
/// takes. Either way the observation dies with the run — rejection feedback is
/// the only channel a review has, and an approval has no channel at all.
///
/// So a review may answer with a list of findings, each carrying a severity.
/// Only a `blocking` finding rejects; an `advisory` one rides along into the
/// item's `## Notes` when the review passes, where the next run and the next
/// human both read it.
///
/// Everything here is deliberately lenient, in the same direction as
/// `StructuredOutputExtractor` and for the same reason — a verdict that cannot
/// be read costs a whole run:
///
/// - No findings at all is the ordinary case, not an error. A bare
///   `{"passed": true}` routes exactly as it did before this existed.
/// - A findings value that is not a readable list is treated as absent, so the
///   run routes on `passed` alone. Malformed structure never invents a verdict.
/// - A severity nobody recognises reads as `advisory`, never as `blocking`.
///   Guessing "blocking" from an unknown word would reject work on a typo; the
///   boolean the reviewer did give still governs.
/// - A missing `passed` is left alone entirely. That is the clarify node's case
///   (`BacklogAutopilot.unreadableVerdictReason`), and a findings list is not a
///   verdict — a run must not be rejected by a field the reviewer never filled.
package enum ReviewFindings {

    /// The key the findings list rides on, in the reviewer's declared output
    /// schema and in the workflow state the graph routes on.
    package static let outputKey = "findings"

    /// The verdict field this can downgrade — never raise. A blocking finding
    /// turns a `true` into a `false`; nothing here ever turns a `false` into a
    /// `true`.
    package static let verdictKey = "passed"

    /// Where a rejection's findings are handed to the next worker pass: the
    /// worker prompt's `{{state.previousFeedback}}` section.
    package static let feedbackKey = "previousFeedback"

    /// Where a rejecting round's drift findings are written, for
    /// `BacklogAutopilot` to copy into the item's `## Notes` — never into
    /// `feedbackKey`, which is the whole point (`markDrift`).
    package static let driftKey = "reviewDrift"

    package enum Severity: String, Sendable, CaseIterable {
        case blocking
        case advisory

        /// Reads a severity out of whatever word the reviewer used. Unknown
        /// wording is `advisory` — see the leniency note on the enum: the cost
        /// of misreading a nit as a blocker is a rejected run.
        package static func parse(_ raw: String?) -> Severity {
            switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "blocking", "blocker", "block", "critical", "major", "must-fix", "must fix":
                return .blocking
            default:
                return .advisory
            }
        }
    }

    package struct Finding: Equatable, Sendable {
        package let severity: Severity
        package let text: String
        /// Optional path the finding is about, kept so a note or a feedback line
        /// points somewhere instead of describing a file the reader must guess.
        package let file: String?
        /// Whether `file` names something outside the item — neither a path the
        /// item's own text cites nor one the run's diff touches. Set by
        /// `markDrift`, never by parsing: a reviewer never declares this about
        /// its own finding, and the whole point is a check independent of what
        /// the reviewer thinks it is doing.
        package let drift: Bool

        package init(severity: Severity, text: String, file: String? = nil, drift: Bool = false) {
            self.severity = severity
            self.text = text
            self.file = file
            self.drift = drift
        }

        /// One line: `path — text`, or just the text when no path was given.
        package var line: String {
            guard let file, !file.trimmingCharacters(in: .whitespaces).isEmpty else { return text }
            return "\(file) — \(text)"
        }

        /// A rough class this finding belongs to, for counting how often a human
        /// overrides findings like it at the approval gate
        /// (`FindingOverrideLedger`). First try, kept simple on purpose and named
        /// here in one place so the grouping can be sharpened later: the file
        /// extension, when there is one, plus the finding's first three words,
        /// lowercased — close enough that "missing CHANGELOG line" and "missing
        /// CHANGELOG entry" land in different classes, but two phrasings of the
        /// same complaint about the same kind of file usually collide.
        package var overrideClass: String {
            let words = text
                .lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .prefix(3)
                .joined(separator: " ")
            let ext = file.map { ($0 as NSString).pathExtension.lowercased() }
            let key = [ext, words].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
            return key.isEmpty ? severity.rawValue : "\(severity.rawValue): \(key)"
        }
    }

    // MARK: - Parsing

    /// The findings in a raw schema value, or nil when there is no readable list
    /// there — absent, prose, an object, a JSON array of nothing usable.
    ///
    /// Nil and `[]` mean the same thing to every caller (route on `passed`
    /// alone); they are distinguished only so a test can tell "unreadable" from
    /// "the reviewer said there were none".
    package static func parse(_ raw: String?) -> [Finding]? {
        guard let raw, let data = raw.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return nil }
        return array.compactMap(finding(from:))
    }

    private static func finding(from element: Any) -> Finding? {
        // A bare string is a finding with no severity — the lenient reading is
        // the one that keeps the words.
        if let text = element as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : Finding(severity: .advisory, text: trimmed)
        }
        guard let object = element as? [String: Any] else { return nil }
        let text = (object["text"] as? String ?? object["message"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let file = (object["file"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Finding(
            severity: Severity.parse(object["severity"] as? String),
            text: text,
            file: file?.isEmpty == true ? nil : file
        )
    }

    /// The findings carried by a review's output. Empty whenever there is
    /// nothing readable — callers that only want to display findings never care
    /// which flavour of nothing they got.
    package static func findings(in output: [String: AnyCodable]) -> [Finding] {
        parse(output[outputKey]?.stringValue) ?? []
    }

    // MARK: - Routing

    /// Applied to the reviewer's completion output before the graph routes on
    /// it: a blocking finding rejects, and the findings become the feedback the
    /// next worker pass is handed.
    ///
    /// Leaves the verdict alone in every case it cannot improve on — no
    /// findings, an unreadable list, or no readable `passed` to reconcile them
    /// against. That is the whole safety property: this can only ever turn an
    /// approval that contradicts itself into the rejection the reviewer's own
    /// findings describe.
    ///
    /// It does always rewrite `previousFeedback`, including to empty. The engine
    /// merges a node's output into execution state and never removes a key, so a
    /// round that says nothing inherits whatever the round before it said: a
    /// worker sent back twice would be handed the *first* review's findings the
    /// second time, as though the reviewer had repeated itself. A review speaks
    /// only for itself, so each one states its feedback outright — even when
    /// that is "none".
    ///
    /// `knownPaths` and `changedFiles` are what a finding's `file` is checked
    /// against for drift (`markDrift`) — the paths the item's own text cites,
    /// and the paths this run's diff touches. `changedFiles` nil means the diff
    /// could not be read at this point, which skips drift marking entirely
    /// rather than inventing one: a caller with nothing to compare against
    /// changes nothing here, exactly as the callers before drift existed did.
    package static func route(
        _ output: [String: AnyCodable],
        knownPaths: Set<String> = [],
        changedFiles: Set<String>? = nil
    ) -> [String: AnyCodable] {
        // No readable verdict: the clarify node owns this, untouched. Its own
        // answer goes through here next, and clears the stale keys then.
        let verdict = output[verdictKey]?.stringValue
        guard verdict == "true" || verdict == "false" else { return output }

        let findings = routedFindings(in: output, knownPaths: knownPaths, changedFiles: changedFiles)
        let blocking = findings.contains { $0.severity == .blocking }
        // A bare verdict with no findings carries no feedback, exactly as before
        // findings existed — and clears any the round before it left behind.
        let rejecting = blocking || verdict == "false"

        var output = output
        if blocking { output[verdictKey] = .string("false") }
        output[feedbackKey] = .string(rejectionFeedback(findings, rejecting: rejecting,
                                                        reason: output["reason"]?.stringValue))
        output[driftKey] = .string(driftNotesIfRejecting(findings, rejecting: rejecting))
        return output
    }

    /// The reviewer's own findings, drift-flagged when there is something to
    /// check them against. `changedFiles` nil — the diff could not be read at
    /// this point — skips `markDrift` entirely, so a caller with nothing to
    /// compare against changes nothing, exactly as it did before drift existed.
    private static func routedFindings(
        in output: [String: AnyCodable],
        knownPaths: Set<String>,
        changedFiles: Set<String>?
    ) -> [Finding] {
        let findings = parse(output[outputKey]?.stringValue) ?? []
        guard let changedFiles else { return findings }
        return markDrift(findings, knownPaths: knownPaths, changedFiles: changedFiles)
    }

    /// What a rejecting round hands the worker — empty for an approving round,
    /// exactly as before findings existed. A drifted finding never becomes an
    /// instruction to the worker — that is the loop this exists to break —
    /// whatever severity the reviewer gave it; it still counted toward
    /// `rejecting` above, so a genuinely blocking round still rejects.
    private static func rejectionFeedback(_ findings: [Finding], rejecting: Bool, reason: String?) -> String {
        guard rejecting else { return "" }
        let onTopic = findings.filter { !$0.drift }
        guard !onTopic.isEmpty else { return "" }
        return feedback(onTopic, reason: reason)
    }

    /// Flags each finding whose `file` names neither a path the item's own text
    /// cites nor one this run's diff touched — a review that pulled the work
    /// somewhere the item never asked it to go. A finding with no `file` is
    /// never flagged: there is nothing to check it against, and guessing would
    /// be exactly the invented signal this stays away from.
    ///
    /// Matched the way `GroundingCheck.isProposed(path:among:)` already matches
    /// a draft's own citations against its own proposals — a suffix either way,
    /// so `Services/Foo.swift` and `Kiteloop/Kiteloop/Services/Foo.swift` are the
    /// same claim. `knownPaths` and `changedFiles` are expected pre-normalised
    /// the way that function expects its `among` set — `GroundingCheck
    /// .SourceIndex.normalize` on each entry.
    package static func markDrift(
        _ findings: [Finding],
        knownPaths: Set<String>,
        changedFiles: Set<String>
    ) -> [Finding] {
        findings.map { finding in
            guard let file = finding.file, !file.isEmpty else { return finding }
            guard !GroundingCheck.isProposed(path: file, among: knownPaths),
                  !GroundingCheck.isProposed(path: file, among: changedFiles) else { return finding }
            return Finding(severity: finding.severity, text: finding.text, file: finding.file, drift: true)
        }
    }

    /// The `## Notes` lines a rejecting round's drift findings are written with
    /// — nil for an approving round, so the human notes only ever gain a line
    /// from a round that actually rejected.
    private static func driftNotesIfRejecting(_ findings: [Finding], rejecting: Bool) -> String {
        guard rejecting else { return "" }
        return driftNotes(findings)
    }

    /// One `drift:` line per drifted finding — `drift:` first so a person
    /// scanning Notes recognises the shape without opening the line. Empty
    /// when nothing in the round drifted, which is every round before this
    /// existed.
    private static func driftNotes(_ findings: [Finding]) -> String {
        findings.filter(\.drift).map { "drift: \($0.line)" }.joined(separator: "\n")
    }

    /// What a rejected run hands the worker: the reviewer's own sentence, then
    /// its findings worst-first, so the blocking ones are read before the nits.
    package static func feedback(_ findings: [Finding], reason: String?) -> String {
        var lines: [String] = []
        if let reason = reason?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty {
            lines.append(reason)
            lines.append("")
        }
        for severity in Severity.allCases {
            for finding in findings where finding.severity == severity {
                lines.append("- [\(severity.rawValue)] \(finding.line)")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Surviving an approval

    /// The `## Notes` lines a *passing* review leaves behind — one per advisory
    /// finding, and nothing at all for a review that had none.
    ///
    /// This is the half of the feature that has no other home: a rejection can
    /// say what it wants in its feedback, but an approval's observations have
    /// nowhere to go once the run ends. `BacklogViewModel.appendNote` stamps the
    /// date; the prefix says where the line came from.
    ///
    /// Takes the *approving review's own output*, not the execution state the
    /// run ends with. State is carry-forward — the engine merges each node's
    /// output over it and never removes a key — so a run whose first review
    /// rejected with findings and whose second approved cleanly would file the
    /// first round's findings against the approval that did not make them.
    package static func advisoryNotes(in output: [String: AnyCodable]) -> [String] {
        findings(in: output)
            .filter { $0.severity == .advisory }
            .map { "review advisory — \($0.line)" }
    }
}
