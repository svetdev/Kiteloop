import XCTest
@testable import KiteloopCore

/// When a worker's already-implemented claim goes to the reviewer, and how a
/// run that sent one there ends.
final class ClaimReviewTests: XCTestCase {

    private let evidence = ["Services/Foo.swift: Foo.bar already does this"]

    // MARK: - Whether the claim is reviewed

    func testAClaimOnAProjectThatLandsReviewPassedWorkIsReviewed() {
        XCTAssertEqual(ClaimReview.evidenceToReview(landsReviewPassedWork: true, claimedEvidence: evidence,
                                                    premiseRefuted: false), evidence)
    }

    func testAClaimOnAProjectThatOnlyProposesWaitsForAPerson() {
        XCTAssertNil(ClaimReview.evidenceToReview(landsReviewPassedWork: false, claimedEvidence: evidence,
                                                  premiseRefuted: false))
    }

    func testARunWithNoClaimOrNoEvidenceIsNotReviewed() {
        XCTAssertNil(ClaimReview.evidenceToReview(landsReviewPassedWork: true, claimedEvidence: nil,
                                                  premiseRefuted: false))
        XCTAssertNil(ClaimReview.evidenceToReview(landsReviewPassedWork: true, claimedEvidence: [],
                                                  premiseRefuted: false))
    }

    func testARefutedPremiseIsNotSentToTheReviewerEvenWithAClaim() {
        XCTAssertNil(ClaimReview.evidenceToReview(landsReviewPassedWork: true, claimedEvidence: evidence,
                                                  premiseRefuted: true))
    }

    func testThePromptBlockListsTheEvidenceAndNothingElse() {
        XCTAssertEqual(ClaimReview.promptBlock(evidence: ["a", "b"]), "  - a\n  - b")
    }

    // MARK: - How the run ends

    func testARunWithNoClaimUnderReviewEndsByTheOrdinaryRules() {
        XCTAssertNil(ClaimReview.none.ending(reviewPassed: true, runWasEmpty: true, gateClosedSignal: nil))
        XCTAssertNil(ClaimReview.none.ending(reviewPassed: false, runWasEmpty: true,
                                             gateClosedSignal: "verify failed (exit 1)"))
    }

    func testAPassedReviewOfAnEmptyRunVerifiesTheClaim() {
        XCTAssertEqual(ClaimReview.underReview(evidence: evidence)
            .ending(reviewPassed: true, runWasEmpty: true, gateClosedSignal: nil),
                       .verified(evidence: evidence))
    }

    func testAPassedReviewOfARunThatChangedFilesIsAnOrdinaryReview() {
        XCTAssertNil(ClaimReview.underReview(evidence: evidence)
            .ending(reviewPassed: true, runWasEmpty: false, gateClosedSignal: nil))
    }

    func testAReviewThatNeverReachedAVerdictLeavesTheClaimUnverified() {
        XCTAssertNil(ClaimReview.underReview(evidence: evidence)
            .ending(reviewPassed: false, runWasEmpty: true, gateClosedSignal: nil))
    }

    func testARedVerifyEndsTheClaimBeforeTheReviewer() {
        XCTAssertEqual(ClaimReview.underReview(evidence: evidence)
            .ending(reviewPassed: false, runWasEmpty: true, gateClosedSignal: "verify failed (exit 1)"),
                       .verifyFailed(signal: "verify failed (exit 1)"))
    }

    func testARejectedClaimEndsRejectedWhateverElseIsTrue() {
        XCTAssertEqual(ClaimReview.rejected.ending(reviewPassed: false, runWasEmpty: true, gateClosedSignal: nil),
                       .rejected)
        XCTAssertEqual(ClaimReview.rejected.ending(reviewPassed: false, runWasEmpty: false, gateClosedSignal: nil),
                       .rejected)
    }

    // MARK: - What the item's Notes say

    func testTheVerifiedNoteSaysTheReviewerCheckedAndNoHumanDid() {
        let note = ClaimReview.verifiedNote(evidence: evidence)
        XCTAssertTrue(note.contains("verified by the reviewer"))
        XCTAssertTrue(note.contains("No human accepted this item"))
        XCTAssertTrue(note.contains("  - Services/Foo.swift: Foo.bar already does this"))
        XCTAssertFalse(note.contains("Nothing has verified that"))
    }

    func testTheRejectedNoteCarriesTheReviewersWords() {
        let note = ClaimReview.rejectedNote(feedback: "AC 2 is unmet\n\n- [blocking] no such route\n")
        XCTAssertTrue(note.contains("rejected by the reviewer"))
        XCTAssertTrue(note.hasSuffix("AC 2 is unmet\n\n- [blocking] no such route"))
    }

    func testARejectionWithNoWordsSaysSo() {
        XCTAssertTrue(ClaimReview.rejectedNote(feedback: " \n").hasSuffix("(no reason given)"))
    }

    func testTheVerifyFailedNoteNamesTheSignal() {
        let note = ClaimReview.verifyFailedNote(signal: "verify failed (exit 1)")
        XCTAssertTrue(note.contains("verify failed (exit 1)"))
        XCTAssertTrue(note.contains("the reviewer did not run"))
    }
}
