import XCTest
@testable import Kiteloop

/// What a new line does to the Diagnostics Logs tab's scroll position. The list
/// used to be pinned to the newest line whenever Auto-scroll was on, which lost
/// a reader's place within a second of scrolling up while the app was busy; it
/// now follows new lines only for a reader at the bottom.
final class DiagnosticsLogScrollTests: XCTestCase {

    func testAReaderAtTheBottomFollowsNewLines() {
        XCTAssertTrue(DiagnosticsView.newLineScrolls(autoScroll: true, distanceFromBottom: 0))
    }

    func testTheBottomIsTheBottomWithinTheTolerance() {
        XCTAssertTrue(DiagnosticsView.newLineScrolls(autoScroll: true, distanceFromBottom: ChatView.atBottomTolerance))
    }

    func testAReaderScrolledUpIsLeftWhereTheyAre() {
        XCTAssertFalse(DiagnosticsView.newLineScrolls(autoScroll: true, distanceFromBottom: 400))
    }

    func testAutoScrollOffNeverScrolls() {
        XCTAssertFalse(DiagnosticsView.newLineScrolls(autoScroll: false, distanceFromBottom: 0))
    }

    /// A log shorter than its pane reads as a negative distance — there is
    /// nothing to scroll, so the reader is at the bottom of it.
    func testALogShorterThanItsPaneFollowsNewLines() {
        XCTAssertTrue(DiagnosticsView.newLineScrolls(autoScroll: true, distanceFromBottom: -120))
    }
}
