import XCTest
@testable import KiteloopCore

/// Covers `ReviewRounds.rounds(steps:)` — the mapping behind the item page's
/// round-by-round list, over the workflow steps a run already recorded. Every
/// assertion here is a fact the reviewer or the worker already wrote to a
/// step's own output; nothing here re-judges the run.
final class ReviewRoundsTests: XCTestCase {

    private func step(_ nodeID: String, _ output: [String: AnyCodable]) -> ExecutionStep {
        ExecutionStep(nodeID: nodeID, agentID: nil, spanID: nil, startedAt: Date(), output: output)
    }

    // MARK: - The ordinary run

    /// A run whose first review passed has exactly one round, and nothing else
    /// to say about it — the common case the page must not grow for.
    func testAFirstPassIsOneRound() {
        let rounds = ReviewRounds.rounds(steps: [
            step("worker", [:]),
            step("reviewer", [ReviewFindings.verdictKey: .string("true"), "reason": .string("looks right")]),
        ])

        XCTAssertEqual(rounds.count, 1)
        XCTAssertEqual(rounds[0].label, "review 1")
        XCTAssertEqual(rounds[0].verdict, .passed)
        XCTAssertEqual(rounds[0].summary, "review 1 · passed")
    }

    /// A run the watchdog ended before any reviewer saw it — a stall, a cost
    /// cap — has no review steps at all. Empty, not a crash.
    func testARunWithNoReviewStepsHasNoRounds() {
        XCTAssertEqual(ReviewRounds.rounds(steps: []), [])
        XCTAssertEqual(ReviewRounds.rounds(steps: [step("worker", [:])]), [])
    }

    // MARK: - Reject, rework, pass

    /// A rejection sends the work back to the worker, and the review that
    /// follows the rework is the run's second round — two rounds, in order,
    /// each with its own verdict and counts.
    func testRejectThenPassIsTwoRoundsInOrder() {
        let rounds = ReviewRounds.rounds(steps: [
            step("worker", [:]),
            step("reviewer", [
                ReviewFindings.verdictKey: .string("false"),
                "reason": .string("AC 3 is unimplemented"),
                ReviewFindings.outputKey: .string(#"[{"severity":"blocking","text":"AC 3 is unimplemented"}]"#),
            ]),
            step("worker", [:]),
            step("reviewer", [ReviewFindings.verdictKey: .string("true"), "reason": .string("AC 3 is met")]),
        ])

        XCTAssertEqual(rounds.map(\.label), ["review 1", "review 2"])
        XCTAssertEqual(rounds.map(\.verdict), [.rejected, .passed])
        XCTAssertEqual(rounds[0].blockingCount, 1)
        XCTAssertEqual(rounds[0].summary, "review 1 · rejected · 1 blocking")
        XCTAssertEqual(rounds[1].summary, "review 2 · passed")
    }

    // MARK: - The clarify follow-up

    /// `reviewer-clarify` is a second question about the same review, not a
    /// second review: it replaces round one's verdict rather than adding a
    /// round of its own.
    func testAClarifyFollowUpUpdatesTheSameRoundRatherThanAddingOne() {
        let rounds = ReviewRounds.rounds(steps: [
            step("reviewer", ["reason": .string("looked at it but said nothing machine-readable")]),
            step("reviewer-clarify", [ReviewFindings.verdictKey: .string("true")]),
        ])

        XCTAssertEqual(rounds.count, 1)
        XCTAssertEqual(rounds[0].label, "review 1")
        XCTAssertEqual(rounds[0].verdict, .passed)
    }

    /// A reviewer whose clarify answer is itself unreadable leaves the round
    /// unreadable rather than guessing a verdict from nothing.
    func testAnUnreadableClarifyAnswerLeavesTheRoundUnreadable() {
        let rounds = ReviewRounds.rounds(steps: [
            step("reviewer", [:]),
            step("reviewer-clarify", ["reason": .string("still just prose")]),
        ])

        XCTAssertEqual(rounds.count, 1)
        XCTAssertEqual(rounds[0].verdict, .unreadable)
        XCTAssertEqual(rounds[0].summary, "review 1 · unreadable")
    }
}
