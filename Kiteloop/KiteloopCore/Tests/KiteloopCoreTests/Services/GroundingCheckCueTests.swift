import XCTest
@testable import KiteloopCore

/// A creation or absence cue *after* the backticked name, in the same
/// sentence, excuses it the way one before it always has — with a binding
/// rule, since a cue between two spans belongs to the later one. On 2026-09-03
/// four of five hand-groomed detail files would have been refused for word
/// order alone: "the policy file `quality.json`, which X creates" was refused
/// while "X creates the policy file `quality.json`" passed. And the refusal
/// now names the cue that would have excused the reference, so the author is
/// not sent to read the check to learn the rule.
final class GroundingCheckCueTests: XCTestCase {

    // MARK: - Fixtures

    /// A repo with one real file and a few real names, so every span in these
    /// drafts that is not excused is refused: nothing below is on disk.
    private let sources = GroundingCheck.Sources(
        pathExists: { $0 == "Kiteloop/Kiteloop/Services/BacklogAutopilot.swift" },
        definesSymbol: { ["BacklogAutopilot", "start"].contains($0) },
        resolvesExecutable: { _ in false }
    )

    private func verdict(_ prose: String) -> GroundingCheck.Verdict {
        let item = BacklogItem(id: "cue-order", title: "Cue order", verify: nil, status: .ready,
                               type: .local, size: .s, detailPath: "backlog/cue-order.md")
        let detail = BacklogItemDetail(id: "cue-order", title: "Cue order", verifyCommands: [],
                                       acceptanceCriteria: [], outOfScope: [], what: prose, approach: nil)
        return GroundingCheck.evaluate(item: item, detail: detail, sources: sources)
    }

    // MARK: - A cue after the name

    /// The shape that was refused: the file first, the verb after, one sentence.
    func testACueAfterTheNameInTheSameSentenceExcusesIt() {
        for prose in ["The policy file `quality.json`, which check-features-map creates.",
                      "The member `finalizeRunRecord`, which this item adds to the server.",
                      "The guide `docs/removed-guide.md` is gone from the tree."] {
            let verdict = verdict(prose)
            XCTAssertTrue(verdict.isGrounded, "\(prose) → \(verdict.summary)")
        }
    }

    /// The control, one word away: the same sentence with no cue after the
    /// name is still a claim that the file is there, and refused.
    func testTheSameSentenceWithoutACueIsStillRefused() {
        let verdict = verdict("The policy file `quality.json`, which check-features-map reads.")
        XCTAssertEqual(verdict.unresolved.map(\.text), ["quality.json"], verdict.summary)
    }

    /// A cue binds forward to the next span in the sentence when there is one:
    /// "create" introduces `bar.json`, and nothing is left for `foo.json`.
    func testACueBeforeALaterSpanBelongsToThatSpanNotTheEarlierOne() {
        let verdict = verdict("`foo.json` needs a successor, so create `bar.json` beside it.")
        XCTAssertEqual(verdict.unresolved.map(\.text), ["foo.json"], verdict.summary)
    }

    /// A cue two sentences on excuses nothing: the sentence ends at its period.
    func testACueTwoSentencesLaterExcusesNothing() {
        let verdict = verdict("See `docs/removed-guide.md` for the shape. It is dense. Then add a summary.")
        XCTAssertEqual(verdict.unresolved.map(\.text), ["docs/removed-guide.md"], verdict.summary)
    }

    /// Two cues before the next span: the nearer one is that span's, the other
    /// stays with the span before it. `foo.json` is reported gone, `bar.json`
    /// is proposed, and neither is a claim.
    func testAnAbsenceCueAndACreationCueEachBindToTheirOwnSpan() {
        let verdict = verdict("`foo.json` is gone, so create `bar.json`.")
        XCTAssertTrue(verdict.isGrounded, verdict.summary)
        XCTAssertFalse(verdict.unresolved.map(\.text).contains("foo.json"), verdict.summary)
        XCTAssertFalse(verdict.unresolved.map(\.text).contains("bar.json"), verdict.summary)
    }

    /// The before-window is untouched: a cue ahead of two names still excuses
    /// both, as it always has.
    func testACueBeforeTwoNamesStillExcusesBoth() {
        let verdict = verdict("Add `Services/Foo.swift` and `Services/Bar.swift` under the package.")
        XCTAssertTrue(verdict.isGrounded, verdict.summary)
    }

    /// A span excused by a cue after it is excused wherever it is named again,
    /// the same two-pass forgiveness a span excused by a cue before it gets.
    func testANameExcusedByACueAfterItIsForgivenInLaterMentions() {
        let verdict = verdict("The policy file `quality.json`, which this item creates.\n"
                              + "Validation: `quality.json` lists every root.")
        XCTAssertTrue(verdict.isGrounded, verdict.summary)
    }

    // MARK: - The sentence after a span

    func testTheSentenceAfterASpanEndsAtTheFirstTerminatorOutsideASpan() {
        XCTAssertEqual(GroundingCheck.sentenceAfter(", which X creates. Then `other`."), ", which X creates")
        XCTAssertEqual(GroundingCheck.sentenceAfter(" is it? Yes"), " is it")
        XCTAssertEqual(GroundingCheck.sentenceAfter(" now! Then"), " now")
        XCTAssertEqual(GroundingCheck.sentenceAfter(" and nothing more"), " and nothing more")
        XCTAssertEqual(GroundingCheck.sentenceAfter(""), "")
    }

    /// A period inside a later span is part of a name, not the end of the
    /// sentence: `bar.json` keeps its sentence going to the real terminator.
    func testATerminatorInsideALaterSpanDoesNotEndTheSentence() {
        XCTAssertEqual(GroundingCheck.sentenceAfter(" is gone, so create `bar.json` now. Next"),
                       " is gone, so create `bar.json` now")
    }

    /// The after-window on its own: one cue with no later span binds back; one
    /// cue ahead of a later span does not; two do, since only the nearer is
    /// the later span's.
    func testACueAfterBindsBackOnlyWhenNoLaterSpanClaimsIt() {
        XCTAssertTrue(GroundingCheck.isExcused(after: ", which X creates."))
        XCTAssertTrue(GroundingCheck.isExcused(after: " is no longer read."))
        XCTAssertFalse(GroundingCheck.isExcused(after: ", so create `bar.json`."))
        XCTAssertTrue(GroundingCheck.isExcused(after: " is gone, so create `bar.json`."))
        XCTAssertFalse(GroundingCheck.isExcused(after: " is read here."))
        XCTAssertFalse(GroundingCheck.isExcused(after: ""))
    }

    /// The window ends with the sentence: a cue past the terminator is in the
    /// next sentence and binds to nothing here.
    func testACueAfterTheSentenceEndsBindsToNothing() {
        XCTAssertFalse(GroundingCheck.isExcused(after: " is read here. Then create it."))
    }

    // MARK: - The refusal names the fix

    func testTheRefusalForAPathSaysHowItWasReadAndWhichCueWouldExcuseIt() {
        let verdict = verdict("See `docs/removed-guide.md` for the rule.")
        XCTAssertEqual(verdict.unresolved.map(\.kind), [.path], verdict.summary)
        XCTAssertTrue(verdict.summary.contains("read as a path; if this draft creates it,"
                                               + " say so in the same sentence with a creation cue ("),
                      verdict.summary)
        XCTAssertTrue(verdict.summary.contains("(add, create, declare, define, …)"), verdict.summary)
        XCTAssertFalse(verdict.summary.contains("read as a symbol"), verdict.summary)
        XCTAssertFalse(verdict.summary.contains("\n"), verdict.summary)
    }

    func testTheRefusalForASymbolSaysHowItWasReadAndWhichCueWouldExcuseIt() {
        let verdict = verdict("Copy the pattern in `phantomToolProvider`.")
        XCTAssertEqual(verdict.unresolved.map(\.kind), [.symbol], verdict.summary)
        XCTAssertTrue(verdict.summary.contains("read as a symbol; if this draft creates it,"
                                               + " say so in the same sentence with a creation cue ("),
                      verdict.summary)
        XCTAssertFalse(verdict.summary.contains("read as a path"), verdict.summary)
    }

    /// The hint sits after the note it belongs to, before the next reference's,
    /// so a two-reference refusal reads as two diagnoses rather than a note, a
    /// note and two hints.
    func testEachRefusedReferenceCarriesItsOwnHint() throws {
        let verdict = verdict("Edit `Kiteloop/Kiteloop/Services/Nope.swift` to call `phantomToolProvider`.")
        XCTAssertEqual(verdict.unresolved.count, 2, verdict.summary)
        let path = try XCTUnwrap(verdict.summary.range(of: "read as a path"))
        let symbolNote = try XCTUnwrap(verdict.summary.range(of: "cites `phantomToolProvider`"))
        XCTAssertTrue(path.upperBound < symbolNote.lowerBound, verdict.summary)
    }

    /// A `verify:` refusal keeps the note it has always had and gains no hint:
    /// a creation cue is not how a missing executable or a missing `cd` is fixed.
    func testAVerifyRefusalCarriesNoCueHint() {
        let item = BacklogItem(id: "cue-order", title: "Cue order", verify: "nonesuch --check",
                               status: .ready, type: .local, size: .s)
        let verdict = GroundingCheck.evaluate(item: item, detail: nil, sources: sources)
        XCTAssertEqual(verdict.unresolved.map(\.kind), [.command], verdict.summary)
        XCTAssertNil(GroundingCheck.Verdict.cueHint(for: .command))
        XCTAssertNil(GroundingCheck.Verdict.cueHint(for: .commandPath))
        XCTAssertFalse(verdict.summary.contains("read as a path"), verdict.summary)
        XCTAssertFalse(verdict.summary.contains("read as a symbol"), verdict.summary)
    }

    /// The closing remedy says where a cue may sit now — the same sentence,
    /// either side — and what a cue after the mention binds to.
    func testTheRemedyClauseSaysACueMaySitOnEitherSideOfTheMention() {
        let verdict = verdict("See `docs/removed-guide.md` for the rule.")
        XCTAssertTrue(verdict.summary.contains("in the same sentence as the backticked mention, before it or after it"),
                      verdict.summary)
        XCTAssertTrue(verdict.summary.contains("belongs to the next backticked span"), verdict.summary)
    }

    /// The sample cues the message quotes are read off the set, uninflected and
    /// in a stable order — written out here so that a change to the message is
    /// a change to this test, and every one of them is a cue that excuses.
    func testTheSampleCuesAreTheFirstUninflectedCuesAndEachExcuses() {
        XCTAssertEqual(GroundingCheck.sampleCreationCues, ["add", "create", "declare", "define"])
        for cue in GroundingCheck.sampleCreationCues {
            let verdict = verdict("The item will \(cue) `docs/new-guide.md` for the rule.")
            XCTAssertTrue(verdict.isGrounded, "\(cue) → \(verdict.summary)")
        }
    }
}
