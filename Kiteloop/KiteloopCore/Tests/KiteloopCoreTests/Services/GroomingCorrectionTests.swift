import XCTest
@testable import KiteloopCore

/// A grooming the grounding check refuses goes back to the groomer: how many
/// times, and what the groomer is told. The rule is `GroundingCheck`'s own —
/// these pin that the correction quotes it and that the rewording it asks for
/// is one the check accepts.
final class GroomingCorrectionTests: XCTestCase {

    // MARK: - Fixtures

    /// A repo where nothing cited exists, so a citation stands or falls on how
    /// it is worded.
    private let sources = GroundingCheck.Sources(
        pathExists: { _ in false }, definesSymbol: { _ in false }, resolvesExecutable: { _ in true })

    private func verdict(_ prose: String) -> GroundingCheck.Verdict {
        let item = BacklogItem(id: "cache-index", title: "Cache the index", verify: "/bin/echo ok",
                               status: .draft, type: .local, size: .s)
        let detail = BacklogItemDetail(id: "cache-index", title: "Cache the index", verifyCommands: [],
                                       acceptanceCriteria: ["It does the thing"], outOfScope: [],
                                       what: prose, approach: "Write it.")
        return GroundingCheck.evaluate(item: item, detail: detail, sources: sources)
    }

    // MARK: - How many rounds

    /// The bound is the one a failing check already gets when it goes back to
    /// a worker, not a number of its own.
    func testTheBoundIsTheFixRoundsAFailingCheckGets() {
        XCTAssertEqual(GroomingCorrection.maxRounds, PullRequestChecks.maxFixRounds)
    }

    func testARefusedGroomingIsOwedARoundUntilTheBoundIsUsed() {
        let refused = verdict("Update `Services/NotAFile.swift` to do the thing.")
        XCTAssertFalse(refused.isGrounded)

        for used in 0..<GroomingCorrection.maxRounds {
            XCTAssertTrue(GroomingCorrection.isOwed(after: refused, roundsUsed: used), "round \(used)")
        }
        XCTAssertFalse(GroomingCorrection.isOwed(after: refused, roundsUsed: GroomingCorrection.maxRounds))
    }

    func testAGroundedGroomingIsOwedNoRound() {
        XCTAssertFalse(GroomingCorrection.isOwed(after: .grounded, roundsUsed: 0))
    }

    // MARK: - The rounds themselves

    private static let refusedProse = "Update `Services/NotAFile.swift` to do the thing."
    private static let groundedProse = "Add a `Services/NotAFile.swift` that does the thing."

    /// A grounded proposal is returned as it came, and nobody is asked to
    /// reword anything.
    func testAGroundedProposalIsSettledWithoutARound() async {
        var asked = 0
        let settled = await GroomingCorrection.settle(Self.groundedProse, grounding: verdict) { _, _ in
            asked += 1
            return Self.refusedProse
        }
        XCTAssertEqual(settled, Self.groundedProse)
        XCTAssertEqual(asked, 0)
    }

    /// The refused proposal and the check's own summary go to the rewording,
    /// and the rounds end at the first grounded answer.
    func testARefusalIsHandedBackWithItsSummaryAndEndsAtTheFirstGroundedAnswer() async {
        var heard: [(proposal: String, summary: String)] = []
        let settled = await GroomingCorrection.settle(Self.refusedProse, grounding: verdict) { refused, summary in
            heard.append((refused, summary))
            return Self.groundedProse
        }
        XCTAssertEqual(settled, Self.groundedProse)
        XCTAssertEqual(heard.count, 1)
        XCTAssertEqual(heard.first?.proposal, Self.refusedProse)
        XCTAssertEqual(heard.first?.summary, verdict(Self.refusedProse).summary)
    }

    /// A groomer that never grounds its citation is asked `maxRounds` times
    /// and no more, and what comes back is its last answer, still refused.
    func testRewordingStopsAtTheBoundAndKeepsTheLastRefusedProposal() async {
        var asked = 0
        let settled = await GroomingCorrection.settle(Self.refusedProse, grounding: verdict) { _, _ in
            asked += 1
            return "Update `Services/StillNotAFile\(asked).swift` to do the thing."
        }
        XCTAssertEqual(asked, GroomingCorrection.maxRounds)
        XCTAssertEqual(settled, "Update `Services/StillNotAFile\(GroomingCorrection.maxRounds).swift` to do the thing.")
        XCTAssertFalse(verdict(settled).isGrounded)
    }

    /// A round that answers nothing ends the rounds and keeps the proposal
    /// that was refused.
    func testARoundWithNoAnswerEndsTheRoundsAndKeepsTheRefusedProposal() async {
        var asked = 0
        let settled = await GroomingCorrection.settle(Self.refusedProse, grounding: verdict) { _, _ -> String? in
            asked += 1
            return nil
        }
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(settled, Self.refusedProse)
    }

    /// A rewording that throws ends the pass with its error.
    func testAThrowingRoundIsRethrown() async {
        struct Failed: Error {}
        do {
            _ = try await GroomingCorrection.settle(Self.refusedProse, grounding: verdict) { _, _ -> String? in
                throw Failed()
            }
            XCTFail("the round's error must reach the caller")
        } catch {
            XCTAssertTrue(error is Failed)
        }
    }

    // MARK: - What the groomer is told

    /// The original request, the refused proposal and the check's summary all
    /// reach the groomer whole — the summary verbatim, since it names each
    /// refused citation and the cue that would have excused it.
    func testThePromptCarriesTheOriginalTheRefusedProposalAndTheSummaryVerbatim() {
        let refused = verdict("Update `Services/NotAFile.swift` to do the thing.")

        let prompt = GroomingCorrection.prompt(original: "Groom this draft backlog item.",
                                               refused: "What:\nUpdate `Services/NotAFile.swift`.",
                                               summary: refused.summary)

        XCTAssertTrue(prompt.hasPrefix("Groom this draft backlog item."), prompt)
        XCTAssertTrue(prompt.contains("What:\nUpdate `Services/NotAFile.swift`."), prompt)
        XCTAssertTrue(prompt.contains(refused.summary), prompt)
        XCTAssertTrue(prompt.contains("refused by the grounding check"), prompt)
    }

    /// The rewording the prompt asks for — the creation named in the same
    /// sentence as the citation — is one the unchanged check accepts.
    func testTheRewordingThePromptAsksForClearsTheCheck() {
        let prompt = GroomingCorrection.prompt(original: "", refused: "", summary: "")
        XCTAssertTrue(prompt.contains("\"add\" or \"create\" in the same sentence"), prompt)

        for prose in ["Add `Services/NotAFile.swift` to do the thing.",
                      "Create `Services/NotAFile.swift` to do the thing."] {
            let reworded = verdict(prose)
            XCTAssertTrue(reworded.isGrounded, "\(prose) → \(reworded.summary)")
        }
    }
}
