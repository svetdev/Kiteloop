import XCTest
@testable import KiteloopCore

final class AutopilotCostBudgetTests: XCTestCase {

    // MARK: - Session exhaustion (checked before an item starts)

    func testSessionNotExhaustedWithoutCap() {
        let budget = AutopilotCostBudget(sessionCapUSD: nil, spentThisSession: 999)
        XCTAssertFalse(budget.isSessionExhausted)
    }

    func testSessionExhaustedAtOrAboveCap() {
        var budget = AutopilotCostBudget(sessionCapUSD: 10.0, spentThisSession: 9.99)
        XCTAssertFalse(budget.isSessionExhausted)

        budget.spentThisSession = 10.0
        XCTAssertTrue(budget.isSessionExhausted)

        budget.spentThisSession = 10.5
        XCTAssertTrue(budget.isSessionExhausted)
    }

    // MARK: - In-flight breach

    func testNoBreachWhenBothCapsHaveHeadroom() {
        let budget = AutopilotCostBudget(sessionCapUSD: 10.0, spentThisSession: 4.0)
        XCTAssertNil(budget.breach(itemSpend: 1.5, itemCap: 2.0))
    }

    func testItemBreachWhenItemSpendExceedsItsCap() {
        let budget = AutopilotCostBudget(sessionCapUSD: 100.0, spentThisSession: 0)
        XCTAssertEqual(budget.breach(itemSpend: 2.5, itemCap: 2.0), .item(cap: 2.0, spent: 2.5))
    }

    func testItemCapIsExclusiveAtTheBoundary() {
        let budget = AutopilotCostBudget(sessionCapUSD: nil)
        XCTAssertNil(budget.breach(itemSpend: 2.0, itemCap: 2.0))
    }

    func testSessionBreachCountsAlreadySpentPlusInFlightItem() {
        // 8.00 already spent, item at 2.50 → 10.50 against a 10.00 session cap.
        let budget = AutopilotCostBudget(sessionCapUSD: 10.0, spentThisSession: 8.0)
        XCTAssertEqual(budget.breach(itemSpend: 2.5, itemCap: nil), .session(cap: 10.0, spent: 10.5))
    }

    func testSessionBreachOutranksItemBreach() {
        // Both caps are blown; the session one must win, because it stops the
        // whole run rather than just this item.
        let budget = AutopilotCostBudget(sessionCapUSD: 10.0, spentThisSession: 9.0)
        XCTAssertEqual(budget.breach(itemSpend: 3.0, itemCap: 2.0), .session(cap: 10.0, spent: 12.0))
    }

    func testSessionCapAloneStillBoundsASingleRunawayItem() {
        // No per-item cap configured: the session cap is the only ceiling, and it
        // has to fire mid-item so one runaway can't spend the whole budget.
        let budget = AutopilotCostBudget(sessionCapUSD: 5.0, spentThisSession: 0)
        XCTAssertNil(budget.breach(itemSpend: 4.9, itemCap: nil))
        XCTAssertEqual(budget.breach(itemSpend: 5.1, itemCap: nil), .session(cap: 5.0, spent: 5.1))
    }

    /// The session cap is exclusive mid-item, like the item cap: landing
    /// exactly on it is not a breach. Exhaustion (`>=`) is the check that runs
    /// before the *next* item starts; the in-flight one is not cut off for
    /// spending precisely what was left.
    func testSessionCapIsExclusiveAtTheBoundaryMidItem() {
        // 8.00 already spent, item at 2.00 → exactly the 10.00 session cap.
        let budget = AutopilotCostBudget(sessionCapUSD: 10.0, spentThisSession: 8.0)
        XCTAssertNil(budget.breach(itemSpend: 2.0, itemCap: nil))
        XCTAssertFalse(budget.isSessionExhausted, "8.00 of 10.00 leaves room to start this item")

        // Over it, and it is the session breach — the hard stop.
        XCTAssertEqual(budget.breach(itemSpend: 2.5, itemCap: nil), .session(cap: 10.0, spent: 10.5))
    }

    func testNoCapsConfiguredNeverBreaches() {
        let budget = AutopilotCostBudget(sessionCapUSD: nil, spentThisSession: 500)
        XCTAssertNil(budget.breach(itemSpend: 250, itemCap: nil))
    }

    /// The two breaches carry different consequences now: an item breach is
    /// advisory (recorded, run continues), a session breach still ends the run.
    /// They must stay distinguishable, and the session breach must keep
    /// outranking the item one — otherwise a runaway item would be recorded as
    /// advisory while quietly spending the whole night's budget.
    func testSessionBreachOutranksItemBreachSoTheHardStopStillFires() {
        let budget = AutopilotCostBudget(sessionCapUSD: 10.0, spentThisSession: 9.0)

        // Over both ceilings: the session breach is the one reported, because it
        // is the one that must still stop the run.
        XCTAssertEqual(budget.breach(itemSpend: 3.0, itemCap: 2.0),
                       .session(cap: 10.0, spent: 12.0))

        // Over the item ceiling only: reported as an item breach, which the
        // autopilot records and continues past.
        let roomy = AutopilotCostBudget(sessionCapUSD: 100.0, spentThisSession: 0)
        XCTAssertEqual(roomy.breach(itemSpend: 3.0, itemCap: 2.0),
                       .item(cap: 2.0, spent: 3.0))

        // Under both: nothing to report.
        XCTAssertNil(roomy.breach(itemSpend: 1.5, itemCap: 2.0))
    }
}
