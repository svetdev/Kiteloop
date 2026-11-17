import XCTest
import KiteloopTestSupport
@testable import KiteloopCore

/// `AttemptDecisions` is what lets a caller answer for something it asked to
/// start without guessing how long deciding takes. The cases here are the ones
/// a timed wait got wrong: a decision that arrives late, a decision left over
/// from an earlier attempt, and a second word about an attempt already decided.
@MainActor
final class AttemptDecisionsTests: XCTestCase {

    /// A waiter is held for as long as there is nothing to say, and resumed by
    /// the decision itself — there is no window for it to fall out of.
    func testAWaiterIsResumedByTheDecisionHoweverLateItIsMade() async throws {
        let decisions = AttemptDecisions<String>()
        let waiter = Task { await decisions.decision(afterAttempt: 0) }
        try await eventually("the waiter to be registered") { decisions.waiterCount == 1 }

        // Still undecided after the main actor has been handed round: nothing
        // but a decision ends the wait.
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(decisions.waiterCount, 1)

        XCTAssertTrue(decisions.decide(attempt: 1, "started"))
        let answer = await waiter.value
        XCTAssertEqual(answer, "started")
        XCTAssertEqual(decisions.waiterCount, 0)
    }

    /// A decision made before anyone asked is still the answer, with no
    /// suspension at all.
    func testADecisionAlreadyMadeAnswersAtOnce() async {
        let decisions = AttemptDecisions<String>()
        decisions.decide(attempt: 1, "refused")

        let answer = await decisions.decision(afterAttempt: 0)

        XCTAssertEqual(answer, "refused")
        XCTAssertEqual(decisions.waiterCount, 0)
    }

    /// An earlier attempt's decision is not an answer about the next one: a
    /// caller that has already seen attempt 1 waits for attempt 2.
    func testAnEarlierAttemptsDecisionDoesNotAnswerTheNextRequest() async throws {
        let decisions = AttemptDecisions<String>()
        decisions.decide(attempt: 1, "refused: stale")
        let waiter = Task { await decisions.decision(afterAttempt: 1) }
        try await eventually("the waiter to be registered") { decisions.waiterCount == 1 }

        decisions.decide(attempt: 2, "started")

        let answer = await waiter.value
        XCTAssertEqual(answer, "started")
    }

    /// An attempt is decided once. What is known first is what every waiter is
    /// told, and a later word about the same attempt changes nothing.
    func testAnAttemptIsDecidedOnce() async {
        let decisions = AttemptDecisions<String>()
        XCTAssertTrue(decisions.decide(attempt: 3, "started"))

        XCTAssertFalse(decisions.decide(attempt: 3, "refused"))
        XCTAssertFalse(decisions.decide(attempt: 2, "refused"))

        XCTAssertEqual(decisions.decidedAttempt, 3)
        let answer = await decisions.decision(afterAttempt: 0)
        XCTAssertEqual(answer, "started")
    }

    /// Several requests can be owed the same decision; a waiter that has
    /// already seen this attempt is left waiting for the next.
    func testEveryWaiterOwedADecisionGetsItAndTheRestKeepWaiting() async throws {
        let decisions = AttemptDecisions<String>()
        let first = Task { await decisions.decision(afterAttempt: 0) }
        let second = Task { await decisions.decision(afterAttempt: 0) }
        let later = Task { await decisions.decision(afterAttempt: 1) }
        try await eventually("all three waiters to be registered") { decisions.waiterCount == 3 }

        decisions.decide(attempt: 1, "one")
        let firstAnswer = await first.value
        let secondAnswer = await second.value
        XCTAssertEqual(firstAnswer, "one")
        XCTAssertEqual(secondAnswer, "one")
        XCTAssertEqual(decisions.waiterCount, 1, "the third has seen attempt 1 already")

        decisions.decide(attempt: 2, "two")
        let laterAnswer = await later.value
        XCTAssertEqual(laterAnswer, "two")
    }
}
