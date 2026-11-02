import XCTest
@testable import Kiteloop

/// The cursor stack is a stack: every push owes exactly one pop, and an
/// unbalanced push leaves its cursor on screen for the rest of the session.
/// The regression these pin down is a project tab closed from under the
/// pointer — the row goes away and the un-hover that would have popped never
/// arrives, so the pointing hand follows you everywhere.
final class HoverCursorTrackerTests: XCTestCase {

    // MARK: - Hovering

    func testHoverPushesOnce() {
        var tracker = HoverCursorTracker()
        XCTAssertEqual(tracker.hoverChanged(to: true), .push)
        XCTAssertTrue(tracker.isHovering)
    }

    /// AppKit reporting the same hover twice must not push twice — the second
    /// push would need a second pop nothing is ever going to send.
    func testHoverReportedTwicePushesOnce() {
        var tracker = HoverCursorTracker()
        XCTAssertEqual(tracker.hoverChanged(to: true), .push)
        XCTAssertEqual(tracker.hoverChanged(to: true), .nothing)
    }

    func testHoverEndingPopsOnce() {
        var tracker = HoverCursorTracker()
        _ = tracker.hoverChanged(to: true)
        XCTAssertEqual(tracker.hoverChanged(to: false), .pop)
        XCTAssertEqual(tracker.hoverChanged(to: false), .nothing)
        XCTAssertFalse(tracker.isHovering)
    }

    /// An un-hover for a hover that never happened owes nothing: a pop with no
    /// push of ours underneath it takes someone else's cursor off the stack.
    func testUnhoverWithoutHoverPopsNothing() {
        var tracker = HoverCursorTracker()
        XCTAssertEqual(tracker.hoverChanged(to: false), .nothing)
    }

    // MARK: - Disappearing

    /// The stuck-cursor case: the view goes away while the pointer is over it.
    func testDisappearingWhileHoveredPopsOnce() {
        var tracker = HoverCursorTracker()
        _ = tracker.hoverChanged(to: true)
        XCTAssertEqual(tracker.disappeared(), .pop)
        XCTAssertFalse(tracker.isHovering)
        XCTAssertEqual(tracker.disappeared(), .nothing)
    }

    func testDisappearingAfterThePointerLeftPopsNothing() {
        var tracker = HoverCursorTracker()
        _ = tracker.hoverChanged(to: true)
        XCTAssertEqual(tracker.hoverChanged(to: false), .pop)
        XCTAssertEqual(tracker.disappeared(), .nothing)
    }

    func testDisappearingWithoutEverHoveringPopsNothing() {
        var tracker = HoverCursorTracker()
        XCTAssertEqual(tracker.disappeared(), .nothing)
    }

    /// Hovering again after a disappear-and-reappear starts from a clean stack.
    func testHoveringAgainAfterDisappearPushesAgain() {
        var tracker = HoverCursorTracker()
        _ = tracker.hoverChanged(to: true)
        _ = tracker.disappeared()
        XCTAssertEqual(tracker.hoverChanged(to: true), .push)
    }
}
