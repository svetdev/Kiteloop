import XCTest
import KiteloopCore
@testable import Kiteloop

/// Leniency tests for the LLM-as-judge output parser: a judge reply in almost
/// any shape should yield a clamped score, and a malformed reply must produce no
/// verdict at all (so a bad judge response never breaks a run).
///
/// The second half is about the difference the parser must preserve: a reply
/// that never came, or came without a verdict, is *unavailable* — not a verdict
/// of zero on every dimension. Those two used to record identically, which made
/// a night the judge spent dying read as a night of terrible work.
final class RunQualityJudgeTests: XCTestCase {

    func testCleanJSON() throws {
        let v = try XCTUnwrap(RunQualityJudge.parse("""
        {"verify_passed": 1, "scope_respected": 0.8, "tests_meaningful": 0.5, "conventions": 0.9, "overall": 0.8, "rationale": "solid"}
        """).verdict)
        XCTAssertEqual(v.overall, 0.8, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(v.dimensions["scope_respected"]), 0.8, accuracy: 0.0001)
        XCTAssertEqual(v.dimensions.count, 4)
        XCTAssertEqual(v.rationale, "solid")
        XCTAssertEqual(v.scopeDeviation, "", "no scope_deviation key means the diff followed How")
    }

    // MARK: - scope_deviation

    /// The travel incident this exists for: a diff that ticks every
    /// Validation line by a route How ruled out. The judge names it in its
    /// own field, separate from `rationale` — `BacklogAutopilot
    /// .judgeAdvisoryFinding` reads this one, not the free-text rationale, to
    /// write the item's advisory note.
    func testScopeDeviationIsParsedWhenPresent() throws {
        let v = try XCTUnwrap(RunQualityJudge.parse(#"""
        {"verify_passed": 1, "scope_respected": 0.4, "overall": 0.83,
         "rationale": "DB looks right", "scope_deviation": "How said run narrate_guide; audio was hand-written with macOS say"}
        """#).verdict)
        XCTAssertEqual(v.scopeDeviation, "How said run narrate_guide; audio was hand-written with macOS say")
    }

    /// Absent entirely — not just empty — reads the same as "": a judge that
    /// never answers the field found nothing to name, same as one that
    /// answered `""` outright.
    func testScopeDeviationDefaultsToEmptyWhenAbsent() throws {
        let v = try XCTUnwrap(RunQualityJudge.parse(#"{"overall": 0.9}"#).verdict)
        XCTAssertEqual(v.scopeDeviation, "")
    }

    /// Whitespace around the judge's answer is trimmed, the same leniency
    /// `rationale` and every other free-text field in this parser gets.
    func testScopeDeviationIsTrimmed() throws {
        let v = try XCTUnwrap(RunQualityJudge.parse(#"""
        {"overall": 0.5, "scope_deviation": "  went around the pipeline  "}
        """#).verdict)
        XCTAssertEqual(v.scopeDeviation, "went around the pipeline")
    }

    func testWrappedInProseAndCodeFence() throws {
        let v = try XCTUnwrap(RunQualityJudge.parse("""
        Sure — here is my verdict:
        ```json
        {"verify_passed": 1, "scope_respected": 1, "tests_meaningful": 1, "conventions": 1, "overall": 1.0}
        ```
        Hope that helps.
        """).verdict)
        XCTAssertEqual(v.overall, 1.0, accuracy: 0.0001)
    }

    func testMissingOverallAveragesDimensions() throws {
        let v = try XCTUnwrap(RunQualityJudge.parse("""
        {"verify_passed": 1.0, "scope_respected": 0.0, "tests_meaningful": 1.0, "conventions": 0.0}
        """).verdict)
        // (1 + 0 + 1 + 0) / 4 = 0.5
        XCTAssertEqual(v.overall, 0.5, accuracy: 0.0001)
    }

    func testStringValuedScores() throws {
        let v = try XCTUnwrap(RunQualityJudge.parse(#"{"overall": "0.65", "verify_passed": "1"}"#).verdict)
        XCTAssertEqual(v.overall, 0.65, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(v.dimensions["verify_passed"]), 1.0, accuracy: 0.0001)
    }

    func testClampsOutOfRange() throws {
        let v = try XCTUnwrap(RunQualityJudge.parse(#"{"overall": 1.5, "verify_passed": -0.2}"#).verdict)
        XCTAssertEqual(v.overall, 1.0, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(v.dimensions["verify_passed"]), 0.0, accuracy: 0.0001)
    }

    func testNonFiniteOverallIsUnavailableNotClamped() {
        // `min`/`max` return their first argument when the comparison is false,
        // so a non-finite value passed straight through the old clamp instead of
        // being pinned to 0...1. It must be rejected instead, same as a missing
        // score.
        XCTAssertEqual(RunQualityJudge.parse(#"{"overall": "nan"}"#), .unavailable(.incomplete))
        XCTAssertEqual(RunQualityJudge.parse(#"{"overall": "inf"}"#), .unavailable(.incomplete))
        XCTAssertEqual(RunQualityJudge.parse(#"{"overall": "-infinity"}"#), .unavailable(.incomplete))
    }

    func testNonFiniteDimensionIsDroppedButOthersStillScore() throws {
        // One unusable dimension doesn't sink the whole verdict — it's left out
        // of `dimensions`, and the reply still scores from what's left.
        let v = try XCTUnwrap(RunQualityJudge.parse("""
        {"verify_passed": "nan", "scope_respected": 1.0, "tests_meaningful": 0.5, "overall": 0.75}
        """).verdict)
        XCTAssertEqual(v.overall, 0.75, accuracy: 0.0001)
        XCTAssertNil(v.dimensions["verify_passed"])
        XCTAssertEqual(try XCTUnwrap(v.dimensions["scope_respected"]), 1.0, accuracy: 0.0001)
        XCTAssertEqual(v.dimensions.count, 2)
    }

    func testMissingOverallAveragesOnlyFiniteDimensions() throws {
        // With `overall` absent, a non-finite dimension must not enter the
        // average that fills in for it either.
        let v = try XCTUnwrap(RunQualityJudge.parse("""
        {"verify_passed": "nan", "scope_respected": 1.0, "tests_meaningful": 0.0}
        """).verdict)
        XCTAssertEqual(v.overall, 0.5, accuracy: 0.0001)
        XCTAssertEqual(v.dimensions.count, 2)
    }

    // MARK: - Unavailable ≠ a verdict of zero

    func testUnparseableReplyIsUnavailableNotAVerdict() {
        // Prose, or half a JSON object, means the judge said nothing this code
        // can read — which is not the same as it saying the work was worthless.
        for reply in ["the run looks great, 8/10", "{not json at all", "```json\n{\"over"] {
            XCTAssertEqual(RunQualityJudge.parse(reply), .unavailable(.unparseable), reply)
            XCTAssertNil(RunQualityJudge.parse(reply).verdict, reply)
        }
    }

    func testEmptyReplyIsUnavailableAsNoReply() {
        // What a judge whose session died leaves behind: nothing at all.
        XCTAssertEqual(RunQualityJudge.parse(""), .unavailable(.noReply))
        XCTAssertEqual(RunQualityJudge.parse("   \n\t "), .unavailable(.noReply))
    }

    func testVerdictWithNoScoresIsUnavailable() {
        // A JSON object with only a rationale has nothing to score — recording
        // it as a zero would invent a judgement nobody made.
        XCTAssertEqual(RunQualityJudge.parse(#"{"rationale": "meh"}"#), .unavailable(.incomplete))
    }

    func testGenuineZeroesAreStillAVerdict() {
        // The other half of the rule: a judge that ran and found every dimension
        // unmet must still record that. Unavailability is decided from the
        // reply, never from the score being low.
        let judgement = RunQualityJudge.parse("""
        {"verify_passed": 0, "scope_respected": 0, "tests_meaningful": 0, \
        "conventions": 0, "overall": 0, "rationale": "nothing was done"}
        """)
        let verdict = judgement.verdict
        XCTAssertNotNil(verdict)
        XCTAssertNil(judgement.unavailability)
        XCTAssertEqual(verdict?.overall, 0)
        XCTAssertEqual(verdict?.dimensions.count, 4)
        XCTAssertEqual(verdict?.dimensions["verify_passed"], 0)
    }

    func testOnlyAskedAndFailedReasonsCountAsFailures() {
        // `disabled` / `cancelled` mean nobody asked — reporting those as judge
        // failures would bury the ones that are.
        XCTAssertFalse(RunQualityJudge.Unavailability.disabled.isFailure)
        XCTAssertFalse(RunQualityJudge.Unavailability.cancelled.isFailure)
        XCTAssertTrue(RunQualityJudge.Unavailability.noReply.isFailure)
        XCTAssertTrue(RunQualityJudge.Unavailability.unparseable.isFailure)
        XCTAssertTrue(RunQualityJudge.Unavailability.incomplete.isFailure)
        XCTAssertTrue(RunQualityJudge.Unavailability.notConfigured.isFailure)
    }

    func testEveryReasonCarriesAnExplanationAndAStableRawValue() {
        // The raw value is written to `task-metrics.jsonl` and the control API,
        // so it is a wire format; the explanation is what a reader is shown.
        for reason in RunQualityJudge.Unavailability.allCases {
            XCTAssertFalse(reason.rawValue.isEmpty)
            XCTAssertFalse(reason.explanation.isEmpty)
            XCTAssertEqual(RunQualityJudge.Unavailability(rawValue: reason.rawValue), reason)
        }
        XCTAssertEqual(RunQualityJudge.Unavailability.noReply.rawValue, "no-reply")
        XCTAssertEqual(RunQualityJudge.Unavailability.notConfigured.rawValue, "not-configured")
    }

    func testFirstJSONObjectHandlesNesting() {
        let extracted = RunQualityJudge.firstJSONObject(in: "prefix {\"a\": {\"b\": 1}} suffix {\"c\": 2}")
        XCTAssertEqual(extracted, "{\"a\": {\"b\": 1}}")
    }

    // MARK: - Braces inside string values

    func testFirstJSONObjectKeepsClosingBraceInsideAString() {
        // A judge quoting Swift writes `}` in prose all the time; counting it
        // would end the object early and hand on half of it.
        let text = #"{"reason": "guard else { return } is missing", "overall": 1}"#
        XCTAssertEqual(RunQualityJudge.firstJSONObject(in: text), text)
    }

    func testFirstJSONObjectKeepsUnmatchedOpeningBraceInsideAString() {
        // The other direction: an unpaired `{` in a string used to leave depth
        // above zero to end of text, so the whole reply extracted as nothing.
        let text = #"{"reason": "the body after `if x {` is unreachable"}"#
        XCTAssertEqual(RunQualityJudge.firstJSONObject(in: text), text)
    }

    func testFirstJSONObjectHandlesEscapedQuoteBeforeABrace() {
        // `\"` must not end the string — if it did, the `}` after it would be
        // read as structure and close the object at the wrong character.
        let text = #"{"reason": "he wrote \"done\" but left } dangling", "overall": 0}"#
        XCTAssertEqual(RunQualityJudge.firstJSONObject(in: text), text)
    }

    func testFirstJSONObjectHandlesEscapedBackslashEndingAString() {
        // A trailing `\\` is an escaped backslash, so the quote after it really
        // does close the string and the following `}` really is the end.
        let text = #"{"reason": "path C:\\", "overall": 0}"#
        XCTAssertEqual(RunQualityJudge.firstJSONObject(in: text), text)
    }

    func testFirstJSONObjectIgnoresQuotesInSurroundingProse() {
        // A lone `"` in the prose around the verdict starts no string — treating
        // it as one would hide the object that follows.
        let extracted = RunQualityJudge.firstJSONObject(in: #"He said "it fails. Verdict: {"overall": 1}"#)
        XCTAssertEqual(extracted, #"{"overall": 1}"#)
    }

    func testParseRationaleQuotingBracedCodeStillScores() throws {
        // The end-to-end shape of the bug: a rationale quoting code came back
        // as `.unavailable(.unparseable)` instead of the score the judge gave.
        let judgement = RunQualityJudge.parse(#"""
        Here is my verdict:
        {"verify_passed": 1, "scope_respected": 0.5, "overall": 0.75,
         "rationale": "the new `flush() {` never closes; `else { return }` above it is dead"}
        """#)
        let v = try XCTUnwrap(judgement.verdict)
        XCTAssertNil(judgement.unavailability)
        XCTAssertEqual(v.overall, 0.75, accuracy: 0.0001)
        XCTAssertEqual(v.rationale, "the new `flush() {` never closes; `else { return }` above it is dead")
    }

    // MARK: - Nested braces in the judge reply

    func testParseIgnoresUnknownNestedObject() throws {
        // A judge that volunteers extra structure must not defeat brace matching.
        let v = try XCTUnwrap(RunQualityJudge.parse("""
        {"overall": 0.7, "breakdown": {"scope": {"note": "ok"}}, "rationale": "fine"}
        """).verdict)
        XCTAssertEqual(v.overall, 0.7, accuracy: 0.0001)
        XCTAssertEqual(v.rationale, "fine")
        XCTAssertTrue(v.dimensions.isEmpty)
    }

    func testParseRationaleContainingBraces() throws {
        // Rationale quoting code — the braces are balanced, so extraction still works.
        let v = try XCTUnwrap(RunQualityJudge.parse(#"""
        {"verify_passed": 1, "overall": 0.4, "rationale": "guard let x = y else { return }"}
        """#).verdict)
        XCTAssertEqual(v.overall, 0.4, accuracy: 0.0001)
        XCTAssertEqual(v.rationale, "guard let x = y else { return }")
    }

    func testParseStopsAtFirstObjectWhenProseHasBraces() throws {
        // Trailing commentary containing braces must not be swallowed into the verdict.
        let v = try XCTUnwrap(RunQualityJudge.parse("""
        {"overall": 0.9, "rationale": "good"}

        Note: the `flush() { ... }` helper still needs work.
        """).verdict)
        XCTAssertEqual(v.overall, 0.9, accuracy: 0.0001)
        XCTAssertEqual(v.rationale, "good")
    }

    // MARK: - buildPrompt

    func testBuildPromptIncludesTitleOutcomeAndDiff() {
        let p = RunQualityJudge.buildPrompt(
            item: makeItem(), detail: nil,
            diff: "--- a/Sync.swift\n+++ b/Sync.swift\n+let retries = 3", diffStat: "",
            outcome: "approved", reviewerRetries: 2
        )
        XCTAssertTrue(p.contains("## Task\nAdd retry to sync\n"))
        XCTAssertTrue(p.contains("## Run outcome\napproved, reviewer retries: 2"))
        XCTAssertTrue(p.contains("## Diff\n```\n"))
        XCTAssertTrue(p.contains("+let retries = 3"))
    }

    func testBuildPromptIncludesDetailSections() {
        let p = RunQualityJudge.buildPrompt(
            item: makeItem(),
            detail: makeDetail(what: "Retry failed syncs.", approach: "Wrap in a backoff loop.",
                               acceptanceCriteria: ["retries 3 times", "logs each attempt"],
                               outOfScope: ["changing the transport"]),
            diff: "diff", diffStat: "", outcome: "approved", reviewerRetries: 0
        )
        XCTAssertTrue(p.contains("### What\nRetry failed syncs."))
        XCTAssertTrue(p.contains("### How\nWrap in a backoff loop."))
        XCTAssertTrue(p.contains("### Validation\n- retries 3 times\n- logs each attempt"))
        XCTAssertTrue(p.contains("### Out of scope\n- changing the transport"))
    }

    func testBuildPromptOmitsEmptyDetailSections() {
        let p = RunQualityJudge.buildPrompt(
            item: makeItem(),
            detail: makeDetail(what: "", approach: nil),
            diff: "diff", diffStat: "", outcome: "rejected", reviewerRetries: 1
        )
        XCTAssertFalse(p.contains("### What"))
        XCTAssertFalse(p.contains("### How"))
        XCTAssertFalse(p.contains("### Validation"))
        XCTAssertFalse(p.contains("### Out of scope"))
    }

    func testBuildPromptMarksMissingDiff() {
        let p = RunQualityJudge.buildPrompt(item: makeItem(), detail: nil, diff: "", diffStat: "",
                                            outcome: "failed", reviewerRetries: 0)
        XCTAssertTrue(p.contains("(no isolated diff available)"))
    }

    func testBuildPromptCapsDiffLength() {
        let diff = String(repeating: "x", count: 9000)
        let p = RunQualityJudge.buildPrompt(item: makeItem(), detail: nil, diff: diff, diffStat: "",
                                            outcome: "approved", reviewerRetries: 0)
        XCTAssertFalse(p.contains(diff))
        XCTAssertTrue(p.contains(String(repeating: "x", count: 8000)))
        XCTAssertFalse(p.contains(String(repeating: "x", count: 8001)))
    }

    // MARK: - An investigation is scored on its own terms

    /// 2026-09-03: the run that measured the item's premise, found one of four
    /// functions qualified and refused the other three was scored 0.55 —
    /// tests_meaningful 0.30 — for adding no tests to a diff that rightly did
    /// not exist. An investigation is handed the report and its own terms:
    /// verify on whether it ran, scope on whether the measurement answered the
    /// premise, and tests declared not applicable.
    func testInvestigationPromptCarriesTheReportAndItsOwnScoringTerms() throws {
        let report = "- refuted: only `evaluate` is over 8; the other three read 4.1, 3.8, 2.0\n- held: the baseline lists all four"
        let p = RunQualityJudge.buildPrompt(
            item: makeItem(),
            detail: makeDetail(what: "Split the four.", premise: ["four functions are over CRAP 8"]),
            diff: "", diffStat: "", outcome: "investigation", reviewerRetries: 0,
            premiseReport: report, investigation: true)
        XCTAssertTrue(p.contains("### Premise (claims the item rests on)\n- four functions are over CRAP 8"), p)
        XCTAssertTrue(p.contains("## Premise report"), p)
        XCTAssertTrue(p.contains(report), p)
        XCTAssertTrue(p.contains("## How to score this run"), p)
        XCTAssertTrue(p.contains("tests_meaningful: null"), p)
        XCTAssertTrue(p.contains("Do not score it 0"), p)
        XCTAssertTrue(p.contains("whether the measurement answered the premise"), p)
        XCTAssertTrue(p.contains("## Run outcome\ninvestigation, reviewer retries: 0"), p)
        let terms = try XCTUnwrap(p.range(of: "## How to score this run"))
        let diff = try XCTUnwrap(p.range(of: "## Diff"))
        XCTAssertTrue(terms.lowerBound < diff.lowerBound, "the terms are read before the (absent) diff")
    }

    /// A run that carried a premise report but built anyway shows the report
    /// — work resting on a refuted claim is a scope failure the judge should
    /// see — without the investigation terms.
    func testPremiseReportIsShownForAnOrdinaryRunWithoutTheInvestigationTerms() {
        let p = RunQualityJudge.buildPrompt(
            item: makeItem(), detail: nil, diff: "+let x = 1", diffStat: "",
            outcome: "awaiting-approval", reviewerRetries: 0,
            premiseReport: "- held: all four are over 8")
        XCTAssertTrue(p.contains("## Premise report"), p)
        XCTAssertTrue(p.contains("- held: all four are over 8"), p)
        XCTAssertFalse(p.contains("## How to score this run"), p)
    }

    /// A plain empty-diff run — no premise, no report — is scored exactly as
    /// before: no terms, the diff marked missing, tests still expected.
    func testAPlainEmptyDiffRunIsScoredAsBefore() {
        let p = RunQualityJudge.buildPrompt(
            item: makeItem(), detail: nil, diff: "", diffStat: "",
            outcome: "blocked:run produced no work — no branch", reviewerRetries: 0)
        XCTAssertTrue(p.contains("(no isolated diff available)"), p)
        XCTAssertFalse(p.contains("Premise"), p)
        XCTAssertFalse(p.contains("## How to score this run"), p)
        XCTAssertFalse(p.contains("tests_meaningful: null"), p)
    }

    /// `null` for a dimension declared not applicable is accepted, kept out of
    /// the dimensions, and — with no `overall` given — out of the average, so
    /// an investigation is not scored down for tests it could not have.
    func testNullTestsMeaningfulIsAcceptedAndExcludedFromTheAggregate() throws {
        let v = try XCTUnwrap(RunQualityJudge.parse("""
        {"verify_passed": 1.0, "scope_respected": 0.8, "tests_meaningful": null, "conventions": 0.9, "rationale": "measured"}
        """).verdict)
        XCTAssertEqual(v.dimensions.count, 3)
        XCTAssertNil(v.dimensions["tests_meaningful"])
        // (1.0 + 0.8 + 0.9) / 3, not / 4 with a 0 in it
        XCTAssertEqual(v.overall, 0.9, accuracy: 0.0001)
    }

    /// The judge's own `overall` still wins when it gives one, null beside it
    /// or not — the parser adds nothing the judge did not say.
    func testNullDimensionDoesNotOverrideAGivenOverall() throws {
        let v = try XCTUnwrap(RunQualityJudge.parse("""
        {"verify_passed": 1, "scope_respected": 1, "tests_meaningful": null, "conventions": 1, "overall": 0.95}
        """).verdict)
        XCTAssertEqual(v.overall, 0.95, accuracy: 0.0001)
        XCTAssertEqual(v.dimensions.count, 3)
    }

    // MARK: - diffStat (the judge's view of what it can't see)

    func testBuildPromptIncludesDiffStatAheadOfTheDiffBody() throws {
        let stat = " KiteloopTests/Services/CoordinatorQueueRefillTests.swift | 248 +++\n1 file changed"
        let p = RunQualityJudge.buildPrompt(item: makeItem(), detail: nil,
                                            diff: "+let x = 1", diffStat: stat,
                                            outcome: "approved", reviewerRetries: 0)
        XCTAssertTrue(p.contains("## Changed files (full diff --stat)\n```\n\(stat)\n```\n"))
        // The stat comes before the (possibly truncated) diff body, since it's
        // what tells the judge what it's about to lose.
        let statRange = try XCTUnwrap(p.range(of: "## Changed files"))
        let diffRange = try XCTUnwrap(p.range(of: "## Diff"))
        XCTAssertLessThan(statRange.lowerBound, diffRange.lowerBound)
    }

    func testBuildPromptOmitsChangedFilesSectionWhenStatIsEmpty() {
        let p = RunQualityJudge.buildPrompt(item: makeItem(), detail: nil, diff: "diff", diffStat: "",
                                            outcome: "approved", reviewerRetries: 0)
        XCTAssertFalse(p.contains("## Changed files"))
    }

    func testBuildPromptMarksTheDiffHeadingWhenTruncated() {
        let diff = String(repeating: "x", count: 9000)
        let p = RunQualityJudge.buildPrompt(item: makeItem(), detail: nil, diff: diff, diffStat: "",
                                            outcome: "approved", reviewerRetries: 0)
        XCTAssertTrue(p.contains("## Diff (truncated — see Changed files above for the full file list)"))
    }

    func testBuildPromptLeavesTheDiffHeadingPlainWhenItFits() {
        let p = RunQualityJudge.buildPrompt(item: makeItem(), detail: nil, diff: "small diff", diffStat: "",
                                            outcome: "approved", reviewerRetries: 0)
        XCTAssertTrue(p.contains("## Diff\n```\n"))
        XCTAssertFalse(p.contains("truncated"))
    }

    // MARK: - isDiffTruncated

    func testIsDiffTruncatedIsFalseForAnEmptyOrSmallDiff() {
        XCTAssertFalse(RunQualityJudge.isDiffTruncated(""))
        XCTAssertFalse(RunQualityJudge.isDiffTruncated(String(repeating: "x", count: 8000)))
    }

    func testIsDiffTruncatedIsTrueOnceTheDiffExceedsTheCap() {
        XCTAssertTrue(RunQualityJudge.isDiffTruncated(String(repeating: "x", count: 8001)))
    }

    // MARK: - judgeAdvisoryFinding
    //
    // The judge scores a run but never decides its outcome: of 533 runs it
    // blocked 7, every one a false block against a stale How. A deviation it
    // names is an advisory finding, at any score.

    private func verdict(overall: Double = 0.83, scopeDeviation: String) -> RunQualityJudge.Verdict {
        RunQualityJudge.Verdict(overall: overall, dimensions: [:], rationale: "looks fine",
                                scopeDeviation: scopeDeviation)
    }

    /// A named deviation is advisory, never blocking — even at a low score.
    func testJudgeAdvisoryFindingIsAdvisoryEvenAtALowScore() throws {
        let finding = try XCTUnwrap(BacklogAutopilot.judgeAdvisoryFinding(
            .scored(verdict(overall: 0.2, scopeDeviation: "How said narrate_guide; audio was hand-written with say"))))
        XCTAssertEqual(finding.severity, .advisory)
        XCTAssertEqual(finding.text, "How said narrate_guide; audio was hand-written with say")
    }

    func testJudgeAdvisoryFindingIsNilWithNoDeviation() {
        XCTAssertNil(BacklogAutopilot.judgeAdvisoryFinding(.scored(verdict(overall: 0.1, scopeDeviation: ""))))
    }

    func testJudgeAdvisoryFindingIsNilWhenJudgementIsUnavailable() {
        for reason in RunQualityJudge.Unavailability.allCases {
            XCTAssertNil(BacklogAutopilot.judgeAdvisoryFinding(.unavailable(reason)),
                         "\(reason) carries no verdict to note")
        }
    }

    // MARK: - Fixtures

    private func makeItem(title: String = "Add retry to sync") -> BacklogItem {
        BacklogItem(id: "sync-retry", title: title, verify: "swift test", status: .active,
                    type: .local, size: .s, queries: nil, cost: nil, completedDate: nil,
                    blockedReason: nil, jiraKey: nil, team: nil, detailPath: nil)
    }

    private func makeDetail(what: String? = nil, approach: String? = nil,
                            acceptanceCriteria: [String] = [],
                            outOfScope: [String] = [], premise: [String] = []) -> BacklogItemDetail {
        BacklogItemDetail(id: "sync-retry", title: "Add retry to sync", status: nil, epic: nil,
                          priority: nil, size: nil, owner: nil, jira: nil, repo: nil,
                          verifyCommands: [], why: nil, acceptanceCriteria: acceptanceCriteria,
                          outOfScope: outOfScope, context: nil, notes: nil,
                          what: what, approach: approach, premise: premise)
    }
}

/// The range `BacklogAutopilot` hands the judge: `runDiffBase` reads where the
/// run's branch forked from `HEAD` (`git merge-base`), and `runDiff`/
/// `runDiffStat` diff from there — every commit the run added, not just the
/// branch's last one, and read before teardown's auto-merge folds the branch
/// back into `HEAD` and leaves that merge-base answering the branch tip
/// itself. Git is scripted, so these assert the arguments the app sends
/// without needing a repo.
@MainActor
final class BacklogAutopilotJudgeDiffTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = try makeTemporaryDirectory(prefix: "judge-diff-base")
    }

    /// An autopilot wired only enough for `projectRoot` to be set — the one
    /// thing `runDiffBase`/`runDiff`/`runDiffStat` read off it.
    private func makeAutopilot() -> BacklogAutopilot {
        let autopilot = BacklogAutopilot()
        autopilot.configure(
            orchestrator: Orchestrator(runtime: MockAgentRuntime()),
            backlogViewModel: BacklogViewModel(
                globalConfigStore: GlobalConfigStore(
                    storageURL: tempDir.appendingPathComponent("global-config.json")
                )
            ),
            projectPath: tempDir.path(percentEncoded: false)
        )
        return autopilot
    }

    private var root: String { tempDir.path(percentEncoded: false) }

    // MARK: - runDiffBase

    func testRunDiffBaseReadsMergeBaseAgainstHEAD() async throws {
        let autopilot = makeAutopilot()
        let runner = ScriptedSubprocessRunner { _ in .init(status: 0, output: "abc123\n") }
        let base = await withScriptedSubprocesses(runner) {
            await autopilot.runDiffBase(branch: "kiteloop/item-1", isolated: true)
        }
        XCTAssertEqual(base, "abc123")
        let call = try XCTUnwrap(runner.calls.first)
        XCTAssertEqual(call.arguments, ["-C", root, "merge-base", "HEAD", "kiteloop/item-1"])
    }

    func testRunDiffBaseIsNilWhenNotIsolated() async throws {
        let autopilot = makeAutopilot()
        let runner = ScriptedSubprocessRunner { _ in .init(status: 0, output: "abc123\n") }
        let base = await withScriptedSubprocesses(runner) {
            await autopilot.runDiffBase(branch: "kiteloop/item-1", isolated: false)
        }
        XCTAssertNil(base)
        XCTAssertTrue(runner.calls.isEmpty, "a live-tree run has no branch of its own to compare")
    }

    func testRunDiffBaseIsNilWhenThereIsNoBranch() async throws {
        let autopilot = makeAutopilot()
        let runner = ScriptedSubprocessRunner { _ in .init(status: 0, output: "abc123\n") }
        let base = await withScriptedSubprocesses(runner) {
            await autopilot.runDiffBase(branch: nil, isolated: true)
        }
        XCTAssertNil(base)
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testRunDiffBaseIsNilWhenGitFails() async throws {
        let autopilot = makeAutopilot()
        let runner = ScriptedSubprocessRunner { _ in .init(status: 1, output: "") }
        let base = await withScriptedSubprocesses(runner) {
            await autopilot.runDiffBase(branch: "kiteloop/item-1", isolated: true)
        }
        XCTAssertNil(base)
    }

    // MARK: - runDiff / runDiffStat

    func testRunDiffAndRunDiffStatReadTheSameBaseBranchRange() async throws {
        let autopilot = makeAutopilot()
        let runner = ScriptedSubprocessRunner { call in
            if call.arguments.contains("--stat") { return .init(output: " a.swift | 2 +-\n1 file changed\n") }
            return .init(output: "diff --git a/a.swift b/a.swift\n+new\n")
        }
        let diff = await withScriptedSubprocesses(runner) {
            await autopilot.runDiff(base: "abc123", branch: "kiteloop/item-1")
        }
        let stat = await withScriptedSubprocesses(runner) {
            await autopilot.runDiffStat(base: "abc123", branch: "kiteloop/item-1")
        }
        XCTAssertEqual(diff, "diff --git a/a.swift b/a.swift\n+new\n")
        XCTAssertEqual(stat, " a.swift | 2 +-\n1 file changed\n")
        let diffCall = try XCTUnwrap(runner.calls.first { !$0.arguments.contains("--stat") })
        let statCall = try XCTUnwrap(runner.calls.first { $0.arguments.contains("--stat") })
        XCTAssertEqual(diffCall.arguments, ["-C", root, "diff", "abc123..kiteloop/item-1"])
        XCTAssertEqual(statCall.arguments, ["-C", root, "diff", "--stat", "abc123..kiteloop/item-1"])
    }

    /// No base — git failed, or the run had no branch — must never fall back to
    /// diffing the whole repository: the judge gets nothing rather than
    /// everything.
    func testRunDiffAndRunDiffStatAreEmptyWithNoBase() async throws {
        let autopilot = makeAutopilot()
        let runner = ScriptedSubprocessRunner { _ in .init(output: "should never be read") }
        let diff = await withScriptedSubprocesses(runner) {
            await autopilot.runDiff(base: nil, branch: "kiteloop/item-1")
        }
        let stat = await withScriptedSubprocesses(runner) {
            await autopilot.runDiffStat(base: nil, branch: "kiteloop/item-1")
        }
        XCTAssertEqual(diff, "")
        XCTAssertEqual(stat, "")
        XCTAssertTrue(runner.calls.isEmpty, "no base means no git call — an empty diff, not one over the whole repo")
    }
}

/// The two decisions `judgeRun` makes before it asks anything: whether there is
/// a judge to ask at all (`judgeToAsk`), and what the judge is told about the
/// run's premise (`premiseFraming`). Both answer without a judge session, so
/// these read them directly — the three "nobody asked" reasons in the order
/// they are decided, and the framing each kind of run carries.
@MainActor
final class BacklogAutopilotJudgeFramingTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = try makeTemporaryDirectory(prefix: "judge-framing")
    }

    // MARK: - judgeToAsk

    func testJudgeToAskHandsBackAJudgeWiredToTheConfiguredStore() throws {
        let store = makeConfigStore()
        let autopilot = makeAutopilot(runtimeFactory: { MockAgentRuntime() }, globalConfigStore: store)
        guard case .ask(let judge) = autopilot.judgeToAsk(for: makeResult(.awaitingApproval)) else {
            return XCTFail("an enabled, configured autopilot has a judge to ask")
        }
        XCTAssertTrue(judge.globalConfigStore === store)
    }

    func testJudgeToAskIsCancelledAheadOfANotConfiguredApp() {
        let autopilot = makeAutopilot()
        // No runtime either — a cancelled run has no finished work to score,
        // and that is the fact worth recording, not the missing wiring.
        XCTAssertEqual(refusal(autopilot.judgeToAsk(for: makeResult(.cancelled))), .cancelled)
    }

    func testJudgeToAskIsNotConfiguredWithoutARuntime() {
        let autopilot = makeAutopilot()
        XCTAssertEqual(refusal(autopilot.judgeToAsk(for: makeResult(.done))), .notConfigured)
    }

    // MARK: - premiseFraming

    func testPremiseFramingCarriesAnInvestigationsOwnReport() async {
        let autopilot = makeAutopilot()
        let framing = await autopilot.premiseFraming(
            itemResult: makeResult(.investigation("Only one of the four qualifies.")),
            executionID: "exec-1")
        XCTAssertEqual(framing.report, "Only one of the four qualifies.")
        XCTAssertTrue(framing.investigation, "an investigation is scored on its finding, not on its diff")
    }

    func testPremiseFramingIsEmptyForAnOrdinaryRunWithNoExecution() async {
        let autopilot = makeAutopilot()
        let framing = await autopilot.premiseFraming(itemResult: makeResult(.done), executionID: nil)
        XCTAssertNil(framing.report)
        XCTAssertFalse(framing.investigation)
    }

    /// An execution id nobody can resolve — the workflow engine has no such
    /// execution — is no report, not an empty-string one: the judge is told
    /// nothing about a premise rather than told the worker claimed nothing.
    func testPremiseFramingIsEmptyWhenTheExecutionIsUnknown() async {
        let autopilot = makeAutopilot()
        let framing = await autopilot.premiseFraming(itemResult: makeResult(.done), executionID: "no-such-execution")
        XCTAssertNil(framing.report)
        XCTAssertFalse(framing.investigation)
    }

    // MARK: - Fixtures

    /// The reason `judgeToAsk` refused, or nil when it handed back a judge.
    private func refusal(_ answer: BacklogAutopilot.JudgeRequest) -> RunQualityJudge.Unavailability? {
        if case .unavailable(let reason) = answer { return reason }
        return nil
    }

    private func makeConfigStore() -> GlobalConfigStore {
        GlobalConfigStore(storageURL: tempDir.appendingPathComponent("global-config.json"))
    }

    /// An autopilot with no `configURL`, so nothing it sets is written, and
    /// with the judge's wiring left out unless a test asks for it — `notConfigured` is one of the answers under test.
    private func makeAutopilot(runtimeFactory: (() -> any AgentRuntime)? = nil,
                               globalConfigStore: GlobalConfigStore? = nil) -> BacklogAutopilot {
        let autopilot = BacklogAutopilot()
        autopilot.configure(
            orchestrator: Orchestrator(runtime: MockAgentRuntime()),
            backlogViewModel: BacklogViewModel(globalConfigStore: makeConfigStore()),
            projectPath: tempDir.path(percentEncoded: false),
            runtimeFactory: runtimeFactory,
            globalConfigStore: globalConfigStore
        )
        return autopilot
    }

    private func makeResult(_ outcome: BacklogAutopilot.ItemResult.Outcome) -> BacklogAutopilot.ItemResult {
        BacklogAutopilot.ItemResult(id: "sync-retry", title: "Add retry to sync", outcome: outcome, duration: 1)
    }
}

/// What the judge's verdict does to an item once a run is scored: a note, and
/// nothing else. A low score with a named deviation on a run that verify,
/// review and the gates passed leaves the item where those put it, with the
/// deviation under `## Notes` as advisory — never `blocked:quality judge`.
@MainActor
final class BacklogAutopilotJudgeNoteTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = try makeTemporaryDirectory(prefix: "judge-note")
    }

    func testALowScoreWithADeviationIsNotedAsAdvisoryAndLeavesTheItemDone() throws {
        let backlog = try makeBacklog()
        let autopilot = BacklogAutopilot()
        autopilot.configure(orchestrator: Orchestrator(runtime: MockAgentRuntime()),
                            backlogViewModel: backlog, projectPath: tempDir.path(percentEncoded: false))

        autopilot.noteJudgeFinding(itemID: "task-1", judgement: .scored(RunQualityJudge.Verdict(
            overall: 0.2, dimensions: [:], rationale: "followed a stale How loosely",
            scopeDeviation: "How named the old parser; the diff used the new one")))

        let detail = try String(contentsOf: tempDir.appending(path: "backlog/task-1.md"), encoding: .utf8)
        let notes = try XCTUnwrap(detail.components(separatedBy: "## Notes").last)
        XCTAssertTrue(notes.contains("quality judge — [advisory] How named the old parser; the diff used the new one"),
                      notes)
        XCTAssertEqual(backlog.item(withID: "task-1")?.status, .done, "the judge's score never moves the item")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: GateRejection.url(projectPath: tempDir.path(percentEncoded: false)).path(percentEncoded: false)),
                       "no judge block is recorded for the next attempt")
    }

    func testAScoreWithNoDeviationWritesNoNote() throws {
        let backlog = try makeBacklog()
        let autopilot = BacklogAutopilot()
        autopilot.configure(orchestrator: Orchestrator(runtime: MockAgentRuntime()),
                            backlogViewModel: backlog, projectPath: tempDir.path(percentEncoded: false))
        let detailURL = tempDir.appending(path: "backlog/task-1.md")
        let before = try String(contentsOf: detailURL, encoding: .utf8)

        autopilot.noteJudgeFinding(itemID: "task-1", judgement: .scored(RunQualityJudge.Verdict(
            overall: 0.3, dimensions: [:], rationale: "thin", scopeDeviation: "")))

        XCTAssertEqual(try String(contentsOf: detailURL, encoding: .utf8), before)
    }

    private func makeBacklog() throws -> BacklogViewModel {
        try FileManager.default.createDirectory(at: tempDir.appending(path: "backlog"),
                                                withIntermediateDirectories: true)
        try "## What\n\nFirst task.\n".write(to: tempDir.appending(path: "backlog/task-1.md"),
                                             atomically: true, encoding: .utf8)
        try """
        ---
        project: demo
        ---

        # Demo Backlog

        ## Epic: Now

        - [x] task-1 | First task | done | size: S → [detail](backlog/task-1.md)
        """.write(to: tempDir.appending(path: "BACKLOG.md"), atomically: true, encoding: .utf8)
        let backlog = BacklogViewModel(
            globalConfigStore: GlobalConfigStore(storageURL: tempDir.appending(path: "global-config.json")))
        backlog.loadForProject(repoPath: tempDir.path(percentEncoded: false))
        return backlog
    }
}
