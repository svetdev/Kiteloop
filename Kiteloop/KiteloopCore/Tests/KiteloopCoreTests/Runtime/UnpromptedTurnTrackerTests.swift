import XCTest
@testable import KiteloopCore

final class UnpromptedTurnTrackerTests: XCTestCase {

    func testLinesAreToldApartByTypeAndSubtype() {
        XCTAssertEqual(BetweenTurnsLine.of(type: "system", subtype: "init"), .turnOpener)
        XCTAssertEqual(BetweenTurnsLine.of(type: "assistant", subtype: nil), .turnOpener)
        XCTAssertEqual(BetweenTurnsLine.of(type: "system", subtype: "task_notification"), .activityNotice)
        XCTAssertEqual(BetweenTurnsLine.of(type: "system", subtype: "background_tasks_changed"), .activityNotice)
        XCTAssertEqual(BetweenTurnsLine.of(type: "rate_limit_event", subtype: nil), .activityNotice)
        XCTAssertEqual(BetweenTurnsLine.of(type: "result", subtype: "success"), .result)
        XCTAssertEqual(BetweenTurnsLine.of(type: "system", subtype: "hook_started"), .other)
        XCTAssertEqual(BetweenTurnsLine.of(type: "user", subtype: nil), .other)
    }

    /// The CLI's own order after a turn's `result` when a background shell
    /// finishes: two notices, then a turn of its own from `init` to `result`.
    func testNoticesAreHeldAndTheInitOpensATurnThatItsResultCloses() {
        var tracker = UnpromptedTurnTracker()
        XCTAssertEqual(tracker.route(.activityNotice, canDeliver: true), .hold)
        XCTAssertEqual(tracker.route(.activityNotice, canDeliver: true), .hold)
        XCTAssertEqual(tracker.route(.turnOpener, canDeliver: true), .open)
        XCTAssertTrue(tracker.isOpen)
        XCTAssertTrue(tracker.resultDelivered(), "the result the open turn's stream carried closes it")
        XCTAssertFalse(tracker.isOpen)
        XCTAssertFalse(tracker.resultDelivered(), "a prompted turn's result closes nothing")
    }

    /// With nobody listening the turn is still open — a send must wait for
    /// it — but its lines go nowhere, except notices, which still wait for the
    /// next turn.
    func testATurnNobodyHearsStaysOpenUntilItsResult() {
        var tracker = UnpromptedTurnTracker()
        XCTAssertEqual(tracker.route(.turnOpener, canDeliver: false), .drop)
        XCTAssertTrue(tracker.isOpen)
        XCTAssertEqual(tracker.route(.turnOpener, canDeliver: true), .drop, "a second assistant line opens nothing")
        XCTAssertEqual(tracker.route(.other, canDeliver: true), .drop)
        XCTAssertEqual(tracker.route(.activityNotice, canDeliver: true), .hold)
        XCTAssertEqual(tracker.route(.result, canDeliver: true), .close)
        XCTAssertFalse(tracker.isOpen)
    }

    func testAStrayResultOrHookLineBetweenTurnsIsDropped() {
        var tracker = UnpromptedTurnTracker()
        XCTAssertEqual(tracker.route(.result, canDeliver: true), .drop)
        XCTAssertEqual(tracker.route(.other, canDeliver: true), .drop)
        XCTAssertFalse(tracker.isOpen)
    }
}
