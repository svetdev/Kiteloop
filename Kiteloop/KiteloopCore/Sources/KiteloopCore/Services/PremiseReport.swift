import Foundation

/// The worker's own check of the item's premise, read off its handoff.
///
/// An item may state, under `## Premise`, the claims it rests on
/// (`BacklogItemDetail.premise`), and the worker is asked to verify each
/// against the tree before it builds anything and to report each at the top
/// of its handoff as `held`, `refuted: <measurement>` or `unverifiable: <why>`.
/// This reads those lines back.
///
/// It exists because of 2026-09-03. An item asserted that four named functions
/// qualified for a change. The first run accepted that and wrote four
/// confident justifications. The best run of the day measured instead, found
/// one of the four qualified, built that one and refused the other three —
/// and `RunQualityJudge` scored it 0.55, marking it down for changing no code
/// and adding no tests, because every run was scored as a diff against a task.
/// A refuted premise is a *result*. This is the shape that lets the run end
/// on it (`BacklogAutopilot.ItemResult.Outcome.investigation`) and lets the
/// judge score the investigation on its own terms.
///
/// Reading is deliberately lenient about list markers and emphasis — `- `,
/// `1.`, backticks, `**` — and strict about the verdict word: `held` stands
/// alone or before a separator, `refuted` and `unverifiable` are followed by a
/// colon or a dash. A worker that writes the word in passing prose ("the lock
/// held") is not filing a report, and a report is what changes an ending.
package struct PremiseReport: Equatable, Sendable {

    package enum Verdict: String, Sendable, CaseIterable {
        case held, refuted, unverifiable
    }

    /// One reported claim: its verdict and the line as the worker wrote it,
    /// list marker stripped, backticks and emphasis kept.
    package struct Line: Equatable, Sendable {
        package let verdict: Verdict
        package let text: String
    }

    package let lines: [Line]

    /// Whether any claim came back refuted — the finding that makes a run
    /// with no diff an investigation rather than a run that produced nothing.
    package var isRefuted: Bool { lines.contains { $0.verdict == .refuted } }

    /// The refuted lines, as written — the measurements a reader at the gate
    /// has to check.
    package var refuted: [String] {
        lines.filter { $0.verdict == .refuted }.map(\.text)
    }

    /// The report as a markdown list, one line per claim — what the reviewer's
    /// and the judge's prompts carry, and what the item's Notes quote.
    package var text: String {
        lines.map { "- \($0.text)" }.joined(separator: "\n")
    }

    /// `1 held, 3 refuted` — the tally, for a log line.
    package var tally: String {
        Verdict.allCases.compactMap { verdict in
            let count = lines.filter { $0.verdict == verdict }.count
            return count == 0 ? nil : "\(count) \(verdict.rawValue)"
        }.joined(separator: ", ")
    }

    /// The finding in the words a run log line uses.
    package var summary: String {
        "worker checked the item's premise and refuted \(refuted.count) of \(lines.count) claim"
            + (lines.count == 1 ? "" : "s")
    }

    /// What goes in the item's `## Notes` when the run ends as an investigation
    /// — the whole interface at the moment a human opens the item and asks why
    /// it is at the gate with no diff behind it. It says that no files changed,
    /// that **nothing has verified the measurement**, and what the worker
    /// reported, claim by claim.
    package var note: String {
        "Investigation — this run changed no files. The worker checked the item's premise "
            + "against the tree before building and refuted it, so it stopped rather than build "
            + "on a claim it had measured false. **Nothing has verified the measurement**, which "
            + "is why the item is waiting for you rather than marked done: approving it accepts "
            + "the report and closes the item as investigated; rejecting it returns the item for "
            + "another attempt — regroom the premise first. The worker's premise report:\n"
            + lines.map { "  - \($0.text)" }.joined(separator: "\n")
    }

    // MARK: - Reading

    /// Verdict-first: `held`, `refuted: …`, `unverifiable — …`, with an optional
    /// list marker and emphasis around the word.
    private static let leading = try! NSRegularExpression(
        pattern: #"^(?:[-*•]\s+|\d+[.)]\s+)?(held|refuted|unverifiable)\b\s*(?:[:—–-]|$)"#,
        options: [.caseInsensitive])

    /// Claim-first: `<claim> — held`, `<claim>: refuted: …`. The verdict word
    /// has to follow a separator and, for the two that carry a reason, be
    /// followed by one; `held` may simply end the line.
    private static let trailing = try! NSRegularExpression(
        pattern: #"^(?:[-*•]\s+|\d+[.)]\s+)?.+?\s*[:—–]\s*(held|refuted|unverifiable)\b\s*(?:[:—–-]|[.)]?\s*$)"#,
        options: [.caseInsensitive])

    /// The report in `message`, or nil when it carries no verdict line at all.
    /// Reads the raw handoff, not the condensed closing message — condensing
    /// joins the lines this parses one by one.
    package static func parse(_ message: String?) -> PremiseReport? {
        guard let message else { return nil }
        let lines = message.components(separatedBy: .newlines).compactMap(line)
        return lines.isEmpty ? nil : PremiseReport(lines: lines)
    }

    /// The list marker a line may start with — stripped from the text kept,
    /// which is otherwise the line as written: the backticks around a symbol
    /// in a measurement are part of the measurement.
    private static let listMarker = #"^(?:[-*•]\s+|\d+[.)]\s+)"#

    private static func line(_ raw: String) -> Line? {
        // Matched with emphasis and backticks removed, so a bold or
        // code-formatted verdict word still reads as the word; kept as written.
        let probe = raw.replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard !probe.isEmpty else { return nil }
        let range = NSRange(probe.startIndex..., in: probe)
        guard let match = leading.firstMatch(in: probe, range: range)
                ?? trailing.firstMatch(in: probe, range: range),
              let wordRange = Range(match.range(at: 1), in: probe),
              let verdict = Verdict(rawValue: probe[wordRange].lowercased()) else { return nil }
        let text = raw.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: listMarker, with: "", options: .regularExpression)
        return Line(verdict: verdict, text: text)
    }
}
