import XCTest
@testable import KiteloopCore

/// `## Premise` — the claims an item rests on, one per bullet, for the worker
/// to check before it builds. Read the way `## Out of Scope` is, written back
/// the way the drafters write the other sections, and absent rather than empty
/// when the item states none.
final class BacklogParserPremiseTests: XCTestCase {

    private func detail(_ body: String) throws -> BacklogItemDetail {
        try XCTUnwrap(BacklogParser.parseDetail("""
        ---
        id: premise-item
        title: An item with a premise
        ---

        ## What

        Change the four qualifying functions.

        \(body)

        ## How

        Touch these files.

        ## Validation

        - [ ] It works
        """, fallbackID: "premise-item"))
    }

    func testPremiseBulletsAreReadOneClaimPerBullet() throws {
        let parsed = try detail("""
        ## Premise

        - `RetryCeiling.evaluate` is over CRAP 8
        - `BacklogAIEditor.map` is over CRAP 8
        """)
        XCTAssertEqual(parsed.premise, ["`RetryCeiling.evaluate` is over CRAP 8",
                                        "`BacklogAIEditor.map` is over CRAP 8"])
        XCTAssertEqual(parsed.what, "Change the four qualifying functions.")
        XCTAssertEqual(parsed.approach, "Touch these files.")
    }

    func testAnItemWithoutTheSectionHasNoPremise() throws {
        XCTAssertEqual(try detail("").premise, [])
    }

    /// The grooming skeletons stamp `## Premise` with a bare `- ` when the
    /// variable is left empty; that is no claim, not an empty claim to verify.
    func testAnEmptySectionAndABareBulletReadAsNoPremise() throws {
        XCTAssertEqual(try detail("## Premise\n").premise, [])
        XCTAssertEqual(try detail("## Premise\n\n- \n").premise, [])
    }

    func testProseUnderThePremiseHeadingIsNotAClaim() throws {
        let parsed = try detail("""
        ## Premise

        These were measured on 2026-09-03.
        - one function qualifies
        """)
        XCTAssertEqual(parsed.premise, ["one function qualifies"])
    }

    /// The writer the drafters share puts the section after `## What` and only
    /// when there is something to put there; the parser reads it back whole.
    func testFiledDraftWritesThePremiseAfterWhatAndTheParserReadsItBack() throws {
        var draft = CoordinatorAction.FiledItemDraft(
            id: "new-item", title: "A new item", size: .m, verify: "swift build",
            what: "The outcome.", how: "Touch these files.",
            validation: ["It works"], outOfScope: ["Everything else"])
        draft.premise = ["one of four qualifies", " ", "the other three do not"]

        let markdown = draft.detailMarkdown
        let what = try XCTUnwrap(markdown.range(of: "## What"))
        let premise = try XCTUnwrap(markdown.range(of: "## Premise"))
        let how = try XCTUnwrap(markdown.range(of: "## How"))
        XCTAssertTrue(what.lowerBound < premise.lowerBound && premise.lowerBound < how.lowerBound, markdown)

        let parsed = try XCTUnwrap(BacklogParser.parseDetail(markdown, fallbackID: draft.id))
        XCTAssertEqual(parsed.premise, ["one of four qualifies", "the other three do not"])
        XCTAssertEqual(draft.detail.premise, parsed.premise)
        XCTAssertEqual(parsed.acceptanceCriteria, ["It works"])
        XCTAssertEqual(parsed.outOfScope, ["Everything else"])
    }

    func testFiledDraftWithoutAPremiseWritesNoHeading() {
        let draft = CoordinatorAction.FiledItemDraft(id: "new-item", title: "A new item",
                                                    what: "The outcome.", how: "Do it.")
        XCTAssertFalse(draft.detailMarkdown.contains("## Premise"), draft.detailMarkdown)
        XCTAssertEqual(draft.detail.premise, [])
    }

    /// `## Out of Scope` reads exactly as it did — the helper the two sections
    /// now share must not have changed what it accepted.
    func testOutOfScopeStillReadsPlainBullets() throws {
        let parsed = try detail("## Out of Scope\n\n- Renaming things\n- The other epic\n")
        XCTAssertEqual(parsed.outOfScope, ["Renaming things", "The other epic"])
        XCTAssertEqual(BacklogParser.plainBullets(["- a", "prose", "  - b", ""]), ["a", "b"])
    }
}
