import XCTest
@testable import Kiteloop

/// Covers the no-work circuit breaker: an item that finished having produced
/// nothing was run against a session that had already died, so the autopilot
/// restarts it before the next item — and pauses if restarting isn't helping,
/// rather than burning the rest of the queue.
///
/// The worktree isolation rules that used to live here moved to
/// `WorktreeSessionTests` along with the code.
final class BacklogAutopilotCircuitBreakerTests: XCTestCase {

    /// Kept as corroboration for `CoordinatorBlockedTriage`, which reads
    /// recorded history where the worktree is long gone. It is **not** what the
    /// run loop triggers on — see `noWorkStreak`.
    func testIsNoWorkBlock() {
        XCTAssertTrue(BacklogAutopilot.isNoWorkBlock(blocked: true, costUSD: 0))       // dead session
        XCTAssertTrue(BacklogAutopilot.isNoWorkBlock(blocked: true, costUSD: 0.02))
        XCTAssertFalse(BacklogAutopilot.isNoWorkBlock(blocked: true, costUSD: 1.5))     // real work, then blocked
        XCTAssertFalse(BacklogAutopilot.isNoWorkBlock(blocked: false, costUSD: 0))      // not blocked
    }

    /// The git signal is what counts — an item with one restarts the agents and
    /// advances the streak.
    func testEmptyItemsAdvanceTheStreak() {
        let signal = RunWorkEvidence.Verdict.noChanges.missingSignal
        XCTAssertEqual(BacklogAutopilot.noWorkStreak(previous: 0, signal: signal), 1)
        XCTAssertEqual(BacklogAutopilot.noWorkStreak(previous: 1, signal: signal), 2)
    }

    /// A normal item — done, or blocked on a real review rejection with work in
    /// its worktree — resets the streak, so blocks spread over a long run never
    /// accumulate into a pause. Cost has no say either way: a $0 reading on an
    /// item that produced work is a cost-attribution failure, not a dead agent.
    func testAnItemThatProducedWorkResetsTheStreak() {
        XCTAssertEqual(BacklogAutopilot.noWorkStreak(previous: 2, signal: nil), 0)
        XCTAssertNil(RunWorkEvidence.Verdict.produced.missingSignal)
        // Nobody could tell (a live-tree run) is not evidence, so it resets too.
        XCTAssertNil(RunWorkEvidence.Verdict.unknown.missingSignal)
    }

    /// Restart, restart, then stop: the bound that keeps a restart that doesn't
    /// fix the cause from becoming a loop through the whole backlog.
    func testTheRunStopsOnlyAfterTheLimit() {
        XCTAssertEqual(BacklogAutopilot.noWorkBlockLimit, 3)
        XCTAssertFalse(BacklogAutopilot.shouldStopForNoWork(streak: 1))
        XCTAssertFalse(BacklogAutopilot.shouldStopForNoWork(streak: 2))
        XCTAssertTrue(BacklogAutopilot.shouldStopForNoWork(streak: 3))
        XCTAssertTrue(BacklogAutopilot.shouldStopForNoWork(streak: 4))
    }

    /// Restarts are logged under their own phase name, which is what answers
    /// "why did this agent restart four times" after an unattended night.
    func testRestartsAreRecordedWithTheirReason() {
        let line = BacklogAutopilot.phaseLine(.agentRestart, [
            ("item", "some-item"),
            ("agent", "worker-1"),
            ("cause", RunWorkEvidence.Verdict.noBranch.missingSignal),
            ("restarted", "true"),
            ("streak", "1"),
        ])
        XCTAssertEqual(line, "phase=agent.restart item=some-item agent=worker-1 "
                       + #"cause="run produced no work — no branch" restarted=true streak=1"#)
    }
}
