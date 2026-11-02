import XCTest
@testable import KiteloopCore

/// Covers the severity split in a reviewer's verdict: only a `blocking` finding
/// rejects, an `advisory` one survives an approval into the item's Notes, and
/// anything unreadable degrades to routing on `passed` alone.
///
/// The leniency cases are the ones with teeth. A run costs real money and a
/// reviewer's judgement is already paid for by the time this reads it, so every
/// ambiguous shape here — no findings, prose where a list was asked for, a
/// severity word nobody recognises, a findings list with no verdict beside it —
/// must land on "route the way you did before findings existed" and never on an
/// invented rejection.
final class ReviewFindingsTests: XCTestCase {

    private func state(passed: String? = nil, reason: String? = nil, findings: String? = nil)
        -> [String: AnyCodable] {
        var state: [String: AnyCodable] = [:]
        if let passed { state["passed"] = .string(passed) }
        if let reason { state["reason"] = .string(reason) }
        if let findings { state[ReviewFindings.outputKey] = .string(findings) }
        return state
    }

    // MARK: - Parsing

    func testParsesSeverityTextAndFile() throws {
        let findings = try XCTUnwrap(ReviewFindings.parse(
            #"[{"severity":"blocking","text":"AC 3 unimplemented","file":"Services/Foo.swift"},"#
            + #"{"severity":"advisory","text":"name reads oddly"}]"#))
        XCTAssertEqual(findings, [
            .init(severity: .blocking, text: "AC 3 unimplemented", file: "Services/Foo.swift"),
            .init(severity: .advisory, text: "name reads oddly", file: nil),
        ])
    }

    func testAbsentFindingsAreUnreadableNotEmpty() {
        XCTAssertNil(ReviewFindings.parse(nil))
    }

    /// A reviewer that writes prose where a list was asked for has said nothing
    /// structured — and must not thereby say "reject".
    func testMalformedFindingsReadAsUnreadable() {
        XCTAssertNil(ReviewFindings.parse("two nits and a blocker, see above"))
        XCTAssertNil(ReviewFindings.parse(#"{"severity":"blocking","text":"not a list"}"#))
    }

    func testEmptyListIsReadableAndEmpty() {
        XCTAssertEqual(ReviewFindings.parse("[]"), [])
    }

    func testBareStringEntryKeepsItsWordsAsAdvisory() {
        XCTAssertEqual(ReviewFindings.parse(#"["the button label is off"]"#),
                       [.init(severity: .advisory, text: "the button label is off")])
    }

    /// Guessing "blocking" from an unrecognised word would reject work over a
    /// typo. The boolean the reviewer did give still governs.
    func testUnknownSeverityReadsAsAdvisory() throws {
        let findings = try XCTUnwrap(ReviewFindings.parse(
            #"[{"severity":"spicy","text":"hmm"},{"text":"no severity at all"}]"#))
        XCTAssertEqual(findings.map(\.severity), [.advisory, .advisory])
    }

    func testBlockingSynonymsAreRecognised() {
        for word in ["blocking", "blocker", "BLOCK", " Critical ", "major", "must-fix"] {
            XCTAssertEqual(ReviewFindings.Severity.parse(word), .blocking, "\(word) should block")
        }
    }

    func testEntriesWithNoTextAreDropped() {
        XCTAssertEqual(ReviewFindings.parse(#"[{"severity":"blocking"},{"text":"   "},42]"#), [])
    }

    // MARK: - Routing

    func testAdvisoryOnlyReviewStillApproves() {
        let routed = ReviewFindings.route(
            state(passed: "true", reason: "good work",
                  findings: #"[{"severity":"advisory","text":"name reads oddly"}]"#))
        XCTAssertEqual(routed["passed"]?.stringValue, "true")
        XCTAssertEqual(routed[ReviewFindings.feedbackKey]?.stringValue, "",
                       "an approval sends the worker nothing")
    }

    func testBlockingFindingRejectsAndBecomesTheFeedback() {
        let routed = ReviewFindings.route(
            state(passed: "true", reason: "looks fine",
                  findings: #"[{"severity":"blocking","text":"AC 3 unimplemented","file":"Foo.swift"}]"#))
        XCTAssertEqual(routed["passed"]?.stringValue, "false",
                       "a blocking finding rejects even when the boolean approved")
        let feedback = routed[ReviewFindings.feedbackKey]?.stringValue
        XCTAssertEqual(feedback, "looks fine\n\n- [blocking] Foo.swift — AC 3 unimplemented")
    }

    func testRejectionCarriesEveryFindingBlockingFirst() throws {
        let routed = ReviewFindings.route(
            state(passed: "false", reason: "sending it back",
                  findings: #"[{"severity":"advisory","text":"nit"},{"severity":"blocking","text":"verify fails"}]"#))
        let feedback = try XCTUnwrap(routed[ReviewFindings.feedbackKey]?.stringValue)
        let blocking = try XCTUnwrap(feedback.range(of: "[blocking] verify fails"))
        let advisory = try XCTUnwrap(feedback.range(of: "[advisory] nit"))
        XCTAssertTrue(blocking.lowerBound < advisory.lowerBound, "blocking findings are read first")
    }

    /// The whole safety property: this can only ever turn a self-contradicting
    /// approval into the rejection the reviewer's own findings describe.
    func testNeverTurnsARejectionIntoAnApproval() {
        let routed = ReviewFindings.route(
            state(passed: "false", findings: #"[{"severity":"advisory","text":"only a nit"}]"#))
        XCTAssertEqual(routed["passed"]?.stringValue, "false")
    }

    func testMalformedFindingsRouteOnPassedAlone() {
        let routed = ReviewFindings.route(
            state(passed: "true", reason: "fine", findings: "a blocker and two nits"))
        XCTAssertEqual(routed["passed"]?.stringValue, "true", "unreadable structure invents nothing")
        XCTAssertEqual(routed[ReviewFindings.outputKey]?.stringValue, "a blocker and two nits",
                       "the words are kept as the reviewer wrote them")
    }

    func testBareVerdictKeepsTodaysRouting() {
        for verdict in ["true", "false"] {
            let routed = ReviewFindings.route(state(passed: verdict, reason: "fine"))
            XCTAssertEqual(routed["passed"]?.stringValue, verdict)
            XCTAssertEqual(routed[ReviewFindings.feedbackKey]?.stringValue, "",
                           "a bare verdict carried no feedback before findings existed either")
        }
    }

    /// Execution state is carry-forward: the engine merges each node's output
    /// over the last and never removes a key. A second review that says nothing
    /// must not inherit the first one's feedback and hand it to the worker as
    /// though it had been said again.
    func testLaterRoundClearsAnEarlierRoundsFeedback() {
        var carried = ReviewFindings.route(
            state(passed: "false", reason: "first pass",
                  findings: #"[{"severity":"blocking","text":"AC 3 unmet"}]"#))
        XCTAssertFalse(carried[ReviewFindings.feedbackKey]?.stringValue?.isEmpty ?? true)

        // Second round: the reviewer rejects again but lists nothing.
        for (key, value) in ReviewFindings.route(state(passed: "false", reason: "still no")) {
            carried[key] = value
        }
        XCTAssertEqual(carried[ReviewFindings.feedbackKey]?.stringValue, "",
                       "the first round's findings must not be re-served as the second's")
    }

    /// A findings list is not a verdict. With no readable `passed` the run takes
    /// the clarify path (`unreadableVerdictReason`) exactly as before — being
    /// rejected by a field the reviewer never filled in is the failure mode.
    // MARK: - Surviving an approval

    func testAdvisoryFindingsBecomeNoteLines() {
        let notes = ReviewFindings.advisoryNotes(in: state(
            passed: "true",
            findings: #"[{"severity":"advisory","text":"name reads oddly","file":"Foo.swift"},"#
                     + #"{"severity":"blocking","text":"not this one"}]"#))
        XCTAssertEqual(notes, ["review advisory — Foo.swift — name reads oddly"],
                       "only advisory findings ride an approval into the Notes")
    }

    func testNoFindingsMeansNoNotes() {
        XCTAssertTrue(ReviewFindings.advisoryNotes(in: state(passed: "true")).isEmpty)
        XCTAssertTrue(ReviewFindings.advisoryNotes(in: state(passed: "true", findings: "prose")).isEmpty)
    }

    // MARK: - Drift

    /// The item cites one file, the diff touches that same file, and the
    /// reviewer raises findings on it and on a second file the item never
    /// named: only the second — the one neither the item nor the diff
    /// accounts for — is drift.
    func testAFindingOutsideTheItemAndTheDiffIsMarkedDriftAndTheOtherIsNot() throws {
        let routed = ReviewFindings.route(
            state(passed: "false", reason: "sending it back",
                  findings: #"[{"severity":"advisory","text":"in scope","file":"Services/Foo.swift"},"#
                          + #"{"severity":"advisory","text":"out of scope","file":"Services/Bar.swift"}]"#),
            knownPaths: ["Services/Foo.swift"],
            changedFiles: ["Services/Foo.swift"])
        let drift = try XCTUnwrap(routed[ReviewFindings.driftKey]?.stringValue)
        XCTAssertEqual(drift, "drift: Services/Bar.swift — out of scope",
                       "only the file neither the item nor the diff names drifts")
    }

    /// A drifted finding on a rejecting round is written to the item's Notes
    /// with the `drift:` prefix, and is never handed to the next worker pass
    /// as an instruction to fix — that loop is what this exists to break.
    func testADriftedFindingOnARejectingRoundGoesToNotesNotToTheWorker() throws {
        let routed = ReviewFindings.route(
            state(passed: "false", reason: "AC 3 is unimplemented",
                  findings: #"[{"severity":"blocking","text":"AC 3 unimplemented","file":"Services/Foo.swift"},"#
                          + #"{"severity":"advisory","text":"unrelated nit","file":"Services/Elsewhere.swift"}]"#),
            knownPaths: ["Services/Foo.swift"],
            changedFiles: ["Services/Foo.swift"])

        let drift = try XCTUnwrap(routed[ReviewFindings.driftKey]?.stringValue)
        XCTAssertEqual(drift, "drift: Services/Elsewhere.swift — unrelated nit")

        let feedback = try XCTUnwrap(routed[ReviewFindings.feedbackKey]?.stringValue)
        XCTAssertTrue(feedback.contains("AC 3 unimplemented"), "the on-topic finding still reaches the worker")
        XCTAssertFalse(feedback.contains("unrelated nit"), "the drifted finding is not handed to the worker as a fix")
        XCTAssertFalse(feedback.contains("Elsewhere.swift"))
    }

    /// A finding with no `file` has nothing to check against knownPaths or
    /// changedFiles, and is never guessed at — it is never marked drift.
    func testAFindingWithNoFileIsNeverMarkedDrift() throws {
        let routed = ReviewFindings.route(
            state(passed: "false", reason: "sending it back",
                  findings: #"[{"severity":"blocking","text":"no file named here"}]"#),
            knownPaths: [],
            changedFiles: [])
        let drift = try XCTUnwrap(routed[ReviewFindings.driftKey]?.stringValue)
        XCTAssertEqual(drift, "", "a finding with no file is never flagged as drift")
        let feedback = try XCTUnwrap(routed[ReviewFindings.feedbackKey]?.stringValue)
        XCTAssertTrue(feedback.contains("no file named here"), "an unflagged finding still reaches the worker")
    }

    /// Drift is advisory only: marking it never changes the verdict a review
    /// already gave, whether that reads as an approval, a plain rejection, or
    /// a rejection whose only reason is itself the drifted finding.
    func testDriftNeverChangesTheVerdict() {
        let approvedWithDrift = ReviewFindings.route(
            state(passed: "true", reason: "looks fine",
                  findings: #"[{"severity":"advisory","text":"nit","file":"Nowhere.swift"}]"#),
            knownPaths: ["Services/Foo.swift"], changedFiles: ["Services/Foo.swift"])
        XCTAssertEqual(approvedWithDrift["passed"]?.stringValue, "true")

        let rejectedForAnOnTopicReason = ReviewFindings.route(
            state(passed: "true", reason: "looks fine",
                  findings: #"[{"severity":"blocking","text":"AC 3 unmet","file":"Services/Foo.swift"},"#
                          + #"{"severity":"advisory","text":"nit","file":"Nowhere.swift"}]"#),
            knownPaths: ["Services/Foo.swift"], changedFiles: ["Services/Foo.swift"])
        XCTAssertEqual(rejectedForAnOnTopicReason["passed"]?.stringValue, "false",
                       "the on-topic blocking finding still rejects regardless of the drift alongside it")

        // A blocking finding that is itself drift still rejects: drift only
        // keeps a finding out of the worker's feedback, never out of the
        // verdict the reviewer's own severity already decided.
        let blockingDriftStillRejects = ReviewFindings.route(
            state(passed: "true", reason: "looks fine",
                  findings: #"[{"severity":"blocking","text":"nowhere near this item","file":"Nowhere.swift"}]"#),
            knownPaths: ["Services/Foo.swift"], changedFiles: ["Services/Foo.swift"])
        XCTAssertEqual(blockingDriftStillRejects["passed"]?.stringValue, "false")
    }

    // MARK: - overrideClass

    /// The extension and the first three words, lowercased — enough that two
    /// phrasings of the same complaint about the same kind of file collide.
    func testOverrideClassCombinesExtensionAndFirstThreeWords() {
        let finding = ReviewFindings.Finding(severity: .blocking,
                                             text: "Missing CHANGELOG line for this change",
                                             file: "CHANGELOG.md")
        XCTAssertEqual(finding.overrideClass, "blocking: md missing changelog line")
    }

    /// Two findings that differ only in wording after the third word still
    /// collide — the class is deliberately coarse.
    func testOverrideClassIgnoresWordsAfterTheFirstThree() {
        let a = ReviewFindings.Finding(severity: .blocking, text: "Missing CHANGELOG line for this change",
                                       file: "CHANGELOG.md")
        let b = ReviewFindings.Finding(severity: .blocking, text: "Missing CHANGELOG line, always",
                                       file: "CHANGELOG.md")
        XCTAssertEqual(a.overrideClass, b.overrideClass)
    }

    /// No file is not the same class as one with an extension — the class must
    /// not silently collapse a filed complaint into an unfiled one.
    func testOverrideClassWithNoFileOmitsTheExtension() {
        let finding = ReviewFindings.Finding(severity: .blocking, text: "Missing CHANGELOG line", file: nil)
        XCTAssertEqual(finding.overrideClass, "blocking: missing changelog line")
    }

    /// Severity is part of the class: the same wording at a different severity
    /// is a different pattern to learn from.
    func testOverrideClassIncludesSeverity() {
        let blocking = ReviewFindings.Finding(severity: .blocking, text: "missing changelog line", file: nil)
        let advisory = ReviewFindings.Finding(severity: .advisory, text: "missing changelog line", file: nil)
        XCTAssertNotEqual(blocking.overrideClass, advisory.overrideClass)
    }
}
