import XCTest
@testable import Kiteloop

/// What a row arriving during a run does to a worker or reviewer pane's scroll
/// position. The pane used to be pinned to the newest row on every change of
/// the total row count, which made reading back over what the worker just did
/// impossible while the run was live; it now follows the stream only for a
/// reader who is at the bottom of it.
final class AutopilotTranscriptScrollTests: XCTestCase {

    func testAReaderAtTheBottomFollowsTheRun() {
        XCTAssertEqual(AutopilotTranscriptView.streamScrollAction(distanceFromBottom: 0), .follow)
    }

    func testTheBottomIsTheBottomWithinTheTolerance() {
        XCTAssertEqual(
            AutopilotTranscriptView.streamScrollAction(distanceFromBottom: ChatView.atBottomTolerance),
            .follow
        )
        XCTAssertEqual(
            AutopilotTranscriptView.streamScrollAction(distanceFromBottom: ChatView.atBottomTolerance.nextUp),
            .stayPut
        )
    }

    func testAReaderScrolledUpIsLeftWhereTheyAre() {
        XCTAssertEqual(AutopilotTranscriptView.streamScrollAction(distanceFromBottom: 400), .stayPut)
    }

    /// A transcript shorter than its pane reads as a negative distance — there
    /// is nothing to scroll, so the reader is at the bottom of it.
    func testATranscriptShorterThanItsPaneFollowsTheRun() {
        XCTAssertEqual(AutopilotTranscriptView.streamScrollAction(distanceFromBottom: -120), .follow)
    }
}
