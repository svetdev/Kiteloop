import Foundation
import KiteloopCore

/// LLM-as-judge: scores a finished autopilot run against the reviewer rubric
/// (see CLAUDE.md → Autonomy). It is a **signal, not a gate** — the score is
/// advisory, feeds metric #3 / the error budget, and never changes item state.
/// The judge is an *independent* one-shot call, not the reviewer agent, to avoid
/// self-preference bias.
@MainActor
struct RunQualityJudge {
    let runtimeFactory: () -> any AgentRuntime
    let globalConfigStore: GlobalConfigStore

    struct Verdict: Sendable, Equatable {
        let overall: Double
        let dimensions: [String: Double]
        let rationale: String
        /// A sentence naming the How or Out of Scope line the diff departs
        /// from, or empty when the diff follows the means the item named.
        /// Unlike `rationale` — read by nobody but a person skimming the log
        /// — a non-empty value here is routed as a blocking finding
        /// (`BacklogAutopilot.judgeBeforeMerge`): a diff that satisfies every
        /// acceptance criterion by a route the item's How ruled out is still
        /// a scope failure, and this is the one field that can say so before
        /// the run merges.
        let scopeDeviation: String
    }

    /// What the judge produced for a run: a verdict, or the reason there isn't
    /// one. The distinction is the whole point — a judge whose session died and
    /// a judge that scored every dimension zero are different facts about a run,
    /// and only the second says anything about the diff. Collapsing them made a
    /// healthy night read as a quality collapse.
    enum Judgement: Sendable, Equatable {
        case scored(Verdict)
        case unavailable(Unavailability)

        /// The verdict when there is one. Callers that only want the score read
        /// this and treat `nil` as "no verdict", exactly as before.
        var verdict: Verdict? {
            if case .scored(let verdict) = self { return verdict }
            return nil
        }

        var unavailability: Unavailability? {
            if case .unavailable(let reason) = self { return reason }
            return nil
        }
    }

    /// Why a run has no score. Decided from the judge's own output — never
    /// inferred from a score being low, which would throw away the genuine
    /// failures the judge exists to catch.
    enum Unavailability: String, Sendable, Equatable, CaseIterable {
        /// The judge was switched off for the project — nothing was asked. No
        /// longer produced; kept so a record written while the switch existed
        /// still reads.
        case disabled
        /// The item was cancelled; there is no finished work to score.
        case cancelled
        /// No runtime to run the judge with (the app isn't configured for it).
        case notConfigured = "not-configured"
        /// The judge session failed or ended without emitting anything. This is
        /// the infrastructure failure the score used to be blamed for.
        case noReply = "no-reply"
        /// A reply arrived carrying no JSON verdict object.
        case unparseable
        /// A verdict object arrived, but with no scores in it.
        case incomplete

        /// True when the judge was actually asked and didn't deliver. The other
        /// cases mean nobody asked, which is not a fault and not worth reporting
        /// as one.
        var isFailure: Bool {
            switch self {
            case .disabled, .cancelled: return false
            case .notConfigured, .noReply, .unparseable, .incomplete: return true
            }
        }

        /// One clause, for a log line or a tooltip — what a reader needs to tell
        /// an infrastructure problem from a quality one.
        var explanation: String {
            switch self {
            case .disabled: return "the quality judge is off for this project"
            case .cancelled: return "the item was cancelled, so there was nothing to score"
            case .notConfigured: return "no runtime was available to run the judge"
            case .noReply: return "the judge produced no output"
            case .unparseable: return "the judge's reply contained no verdict"
            case .incomplete: return "the judge's verdict contained no scores"
            }
        }
    }

    /// "Missing tests" is qualified by "for a run that changed code" on
    /// purpose: on 2026-09-03 the run that measured an item's premise, found
    /// one of four named functions qualified and refused to build the other
    /// three was scored 0.55 — tests_meaningful 0.30 — for adding no tests to
    /// a diff that, correctly, did not exist. A dimension the prompt declares
    /// not applicable is answered `null`, and `parse` leaves it out of the
    /// aggregate rather than reading it as 0.
    private static let systemPrompt = """
    You are a strict, independent code-review quality judge. Given a task spec, the \
    run's diff, and its outcome, score how well the work satisfies the task. Be \
    critical; unrelated changes and, for a run that changed code, missing tests \
    should lower the score. When the prompt says a dimension does not apply to \
    this run, answer null for it and average `overall` over the rest.
    Separately from the scores: does the diff do what the task's How says, by the \
    means How names — not just produce output that happens to satisfy Validation \
    by some other route? An item whose How names a command, a library or a \
    pipeline is not satisfied by another route that produces similar-looking \
    output, and a diff that goes around Out of Scope the same way is the same \
    failure. If so, name the departure in "scope_deviation": the How or Out of \
    Scope line the diff departs from and what it did instead, in one sentence. \
    Leave "scope_deviation" empty when the diff follows the means How named, or \
    when the item's How does not name a specific means.
    Respond with ONE JSON object only — no prose, no code fences:
    {"verify_passed": <0..1>, "scope_respected": <0..1>, "tests_meaningful": <0..1>|null, \
    "conventions": <0..1>, "overall": <0..1>, "rationale": "<= 200 chars", \
    "scope_deviation": "<= 200 chars, or empty"}
    """

    func judge(
        item: BacklogItem,
        detail: BacklogItemDetail?,
        diff: String,
        diffStat: String,
        outcome: String,
        reviewerRetries: Int,
        projectPath: String,
        premiseReport: String? = nil,
        investigation: Bool = false
    ) async -> Judgement {
        let prompt = Self.buildPrompt(item: item, detail: detail, diff: diff, diffStat: diffStat,
                                      outcome: outcome, reviewerRetries: reviewerRetries,
                                      premiseReport: premiseReport, investigation: investigation)
        // A session that dies mid-judgement throws here, or returns the empty
        // string the runtime accumulated before it went. Both are "the judge
        // never answered" — not a verdict of zero on every dimension.
        guard let response = try? await HeadlessAgentRunner.run(
            prompt: prompt,
            cwd: URL(fileURLWithPath: projectPath),
            systemPrompt: Self.systemPrompt,
            agentName: "Quality Judge",
            runtimeFactory: runtimeFactory,
            globalConfigStore: globalConfigStore
        ) else { return .unavailable(.noReply) }
        return Self.parse(response)
    }

    /// How much of the diff body the judge is shown. `git diff --stat`'s output
    /// (`diffStat` below) is not subject to this — it is bounded by file count,
    /// not line count, so it stays whole on a diff whose body this cap would cut.
    nonisolated static let diffCharacterLimit = 8000

    /// Whether `diff` — the raw text `buildPrompt` truncates — didn't fit inside
    /// `diffCharacterLimit`. Read by the caller alongside the verdict: a score
    /// taken through a truncated window is a different fact from one taken over
    /// the whole diff, and this is what tells the two apart. An empty diff (no
    /// isolated diff available) is never truncated.
    nonisolated static func isDiffTruncated(_ diff: String) -> Bool {
        diff.count > diffCharacterLimit
    }

    // MARK: - Pure helpers (testable)

    /// `premiseReport` is the worker's own check of the item's `## Premise`
    /// (`PremiseReport.text`), shown whenever there is one — a run that built
    /// on a claim it had refuted is a scope failure the judge should see.
    /// `investigation` is the ending where that report *is* the result: the
    /// premise was refuted and no code changed, and the run is scored on
    /// whether the measurement answered the premise, not on the diff it
    /// rightly did not produce.
    nonisolated static func buildPrompt(item: BacklogItem, detail: BacklogItemDetail?, diff: String,
                                        diffStat: String, outcome: String, reviewerRetries: Int,
                                        premiseReport: String? = nil, investigation: Bool = false) -> String {
        var p = taskSection(item: item, detail: detail)
        p += "\n## Run outcome\n\(outcome), reviewer retries: \(reviewerRetries)\n"
        if let premiseReport, !premiseReport.isEmpty {
            p += "\n## Premise report (the worker's check of the item's premise, claim by claim)\n"
                + premiseReport + "\n"
        }
        if investigation { p += investigationScoring }
        // The full shape of the diff — every file, with its added/deleted line
        // counts — ahead of the body that may be cut short below. `git diff
        // --stat` is cheap and bounded by file count, so it says "were tests
        // added" even on a diff too large for the body to show it.
        if !diffStat.isEmpty {
            p += "\n## Changed files (full diff --stat)\n```\n\(diffStat)\n```\n"
        }
        let truncated = isDiffTruncated(diff)
        let capped = diff.isEmpty ? "(no isolated diff available)" : String(diff.prefix(diffCharacterLimit))
        let heading = truncated
            ? "## Diff (truncated — see Changed files above for the full file list)"
            : "## Diff"
        p += "\n\(heading)\n```\n\(capped)\n```\n"
        return p
    }

    /// The item as the judge reads it: title, then whichever of the detail's
    /// sections it has. Its own function so `buildPrompt` stays under the
    /// complexity gate now that it also carries the premise report and the
    /// investigation terms.
    private nonisolated static func taskSection(item: BacklogItem, detail: BacklogItemDetail?) -> String {
        var p = "## Task\n\(item.title)\n"
        if let what = detail?.what, !what.isEmpty { p += "\n### What\n\(what)\n" }
        if let premise = detail?.premise, !premise.isEmpty {
            p += "\n### Premise (claims the item rests on)\n" + premise.map { "- \($0)" }.joined(separator: "\n") + "\n"
        }
        if let how = detail?.approach, !how.isEmpty { p += "\n### How\n\(how)\n" }
        if let ac = detail?.acceptanceCriteria, !ac.isEmpty {
            p += "\n### Validation\n" + ac.map { "- \($0)" }.joined(separator: "\n") + "\n"
        }
        if let oos = detail?.outOfScope, !oos.isEmpty {
            p += "\n### Out of scope\n" + oos.map { "- \($0)" }.joined(separator: "\n") + "\n"
        }
        return p
    }

    /// How an investigation is scored — the terms the judge is given in place
    /// of "how well does this diff satisfy the task", because there is no diff
    /// and that is the correct result. `tests_meaningful` is declared not
    /// applicable here, and only here: a plain empty run is still scored as
    /// it always was.
    nonisolated static let investigationScoring = """

    ## How to score this run
    This run is an investigation: the worker checked the item's premise against the \
    tree before building, refuted it, and changed no code — a legitimate ending under \
    the Definition-of-Done, not a run that produced nothing. Score it on its own terms:
    - verify_passed: whether the item's verify ran and passed on the tree as left.
    - scope_respected: whether the measurement answered the premise — each claim \
    checked against the tree, and the report saying what, if anything, still qualifies.
    - tests_meaningful: null. Not applicable — no code changed, so there is nothing a \
    test could assert. Do not score it 0.
    - conventions: whether the report is specific enough to check — numbers, files, \
    symbols — rather than a restatement of the premise.
    Average `overall` over the three dimensions you scored.

    """

    /// The judge's reply as a judgement. Every failure to find a verdict in it
    /// is reported as *unavailable*, with which failure it was — a reply that
    /// never arrived, one with no JSON in it, and one whose JSON carries no
    /// scores are three different stories, and none of them is a score.
    nonisolated static func parse(_ text: String) -> Judgement {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .unavailable(.noReply)
        }
        guard let json = firstJSONObject(in: text),
              let data = json.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .unavailable(.unparseable)
        }

        // A `null` dimension — what the judge is told to answer for one the
        // prompt declared not applicable (`investigationScoring`) — is neither
        // an NSNumber nor a String, so it reads as absent: left out of `dims`,
        // and out of the average below. Reading it as 0 is the 2026-09-03
        // scoring this exists to end.
        //
        // A score that isn't finite ("nan", "inf") is rejected here rather than
        // clamped: `min`/`max` return their first argument when the comparison
        // is false, so a non-finite value would pass through 0...1 unchanged
        // instead of being pinned to it. Treating it as absent — same as a key
        // that was never there — keeps every downstream reader (thresholds,
        // formatting, encoding) working with a value that is either finite or
        // simply not present.
        func score(_ key: String) -> Double? {
            if let n = obj[key] as? NSNumber { return n.doubleValue.isFinite ? n.doubleValue : nil }
            if let s = obj[key] as? String, let d = Double(s), d.isFinite { return d }
            return nil
        }
        func clamp(_ v: Double) -> Double { min(max(v, 0), 1) }

        var dims: [String: Double] = [:]
        for key in ["verify_passed", "scope_respected", "tests_meaningful", "conventions"] where score(key) != nil {
            dims[key] = clamp(score(key)!)
        }
        let overall: Double?
        if let o = score("overall") {
            overall = clamp(o)
        } else if !dims.isEmpty {
            overall = dims.values.reduce(0, +) / Double(dims.count)
        } else {
            overall = nil
        }
        guard let overallScore = overall else { return .unavailable(.incomplete) }
        let scopeDeviation = (obj["scope_deviation"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return .scored(Verdict(overall: overallScore, dimensions: dims,
                               rationale: (obj["rationale"] as? String) ?? "",
                               scopeDeviation: scopeDeviation))
    }

    /// Every balanced `{...}` object in free text, in the order they appear
    /// (tolerates code fences / prose).
    ///
    /// Braces inside a double-quoted string are not structure — a judge whose
    /// `rationale` quotes Swift writes them constantly, and counting them would
    /// either close the object early (handing on a truncated fragment) or never
    /// close it at all. So the scan tracks whether it is inside a string and
    /// skips the character after a backslash, counting braces only outside.
    ///
    /// String tracking applies only once inside an object: a lone `"` in the
    /// prose around the verdict is not the start of anything, and treating it as
    /// one would hide the object that follows it.
    ///
    /// All of them rather than only the first, because there is now a reader
    /// that wants a *particular* object rather than the leading one:
    /// `RunWorkEvidence.AlreadyImplementedClaim` looks for the worker's claim in
    /// a closing message that may well have quoted some other JSON ahead of it.
    /// One scanner behind both, so they cannot come to disagree about where an
    /// object ends.
    nonisolated static func jsonObjects(in text: String) -> [String] {
        let chars = Array(text)
        var found: [String] = []
        var start: Int?
        var depth = 0
        var inString = false
        var escaped = false
        for (i, c) in chars.enumerated() {
            if inString {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
                continue
            }
            if c == "\"" {
                inString = depth > 0
            } else if c == "{" {
                if depth == 0 { start = i }
                depth += 1
            } else if c == "}" {
                depth -= 1
                if depth == 0, let s = start {
                    found.append(String(chars[s...i]))
                    start = nil
                }
            }
        }
        return found
    }

    /// First balanced `{...}` object in free text — `jsonObjects` and its
    /// reading of braces, stopped at the leading one.
    nonisolated static func firstJSONObject(in text: String) -> String? {
        jsonObjects(in: text).first
    }
}
