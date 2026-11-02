import XCTest
@testable import Kiteloop

/// What a chunk arriving during a turn does to the bubble list's scroll
/// position. The list used to be pinned to the newest message every second for
/// the whole of a turn, which made reading anything earlier while an agent
/// worked impossible; it now follows the stream only for a reader who is at the
/// bottom of it.
final class ChatViewStreamScrollTests: XCTestCase {

    func testAReaderAtTheBottomFollowsTheStream() {
        XCTAssertEqual(
            ChatView.streamScrollAction(distanceFromBottom: 0, isSearching: false, hasMatches: false),
            .follow
        )
    }

    func testTheBottomIsTheBottomWithinTheTolerance() {
        XCTAssertEqual(
            ChatView.streamScrollAction(
                distanceFromBottom: ChatView.atBottomTolerance,
                isSearching: false,
                hasMatches: false
            ),
            .follow
        )
        XCTAssertEqual(
            ChatView.streamScrollAction(
                distanceFromBottom: ChatView.atBottomTolerance.nextUp,
                isSearching: false,
                hasMatches: false
            ),
            .stayPut
        )
    }

    func testAReaderScrolledUpIsLeftWhereTheyAre() {
        XCTAssertEqual(
            ChatView.streamScrollAction(distanceFromBottom: 400, isSearching: false, hasMatches: false),
            .stayPut
        )
    }

    /// A list shorter than its window reads as a negative distance — there is
    /// nothing to scroll, so the reader is at the bottom of it.
    func testAListShorterThanItsWindowFollowsTheStream() {
        XCTAssertEqual(
            ChatView.streamScrollAction(distanceFromBottom: -120, isSearching: false, hasMatches: false),
            .follow
        )
    }

    func testAnOpenBarWithMatchesHoldsTheViewOnItsMatch() {
        for distance in [CGFloat(0), ChatView.atBottomTolerance, 400] {
            XCTAssertEqual(
                ChatView.streamScrollAction(
                    distanceFromBottom: distance,
                    isSearching: true,
                    hasMatches: true
                ),
                .holdOnMatch,
                "distance \(distance)"
            )
        }
    }

    /// An open bar with nothing to hold onto leaves the decision to where the
    /// reader is.
    func testAnOpenBarWithNoMatchesDefersToTheDistance() {
        XCTAssertEqual(
            ChatView.streamScrollAction(distanceFromBottom: 0, isSearching: true, hasMatches: false),
            .follow
        )
        XCTAssertEqual(
            ChatView.streamScrollAction(distanceFromBottom: 400, isSearching: true, hasMatches: false),
            .stayPut
        )
    }

    // MARK: - Which distance a scroll report keeps

    /// The failure the recording exists to prevent: a reader at the bottom, a
    /// chunk arrives and pushes the end of the conversation below the window.
    /// Nobody scrolled, so the reader is still following and the next chunk
    /// must still pin the list to the newest message.
    func testContentArrivingUnderAReaderAtTheBottomKeepsThemFollowing() {
        let kept = ChatView.recordedDistance(offset: 500, distanceFromBottom: 320,
                                             lastOffset: 500, recorded: 0)
        XCTAssertEqual(kept, 0)
        XCTAssertEqual(ChatView.streamScrollAction(distanceFromBottom: kept, isSearching: false, hasMatches: false),
                       .follow)
    }

    /// Scrolling up to read something earlier is taken down, so the stream
    /// leaves the reader where they went.
    func testScrollingUpIsRecordedAndTheStreamLeavesTheReaderThere() {
        let kept = ChatView.recordedDistance(offset: 200, distanceFromBottom: 620,
                                             lastOffset: 500, recorded: 0)
        XCTAssertEqual(kept, 620)
        XCTAssertEqual(ChatView.streamScrollAction(distanceFromBottom: kept, isSearching: false, hasMatches: false),
                       .stayPut)
    }

    /// Scrolling back down to the end picks the stream up again.
    func testScrollingBackToTheBottomResumesFollowing() {
        let kept = ChatView.recordedDistance(offset: 820, distanceFromBottom: 0,
                                             lastOffset: 200, recorded: 620)
        XCTAssertEqual(kept, 0)
        XCTAssertEqual(ChatView.streamScrollAction(distanceFromBottom: kept, isSearching: false, hasMatches: false),
                       .follow)
    }

    /// Content arriving under a reader who scrolled up does not move what was
    /// recorded either — they stay where they are, not further away.
    func testContentArrivingUnderAScrolledUpReaderKeepsTheirPlace() {
        XCTAssertEqual(ChatView.recordedDistance(offset: 200, distanceFromBottom: 940,
                                                 lastOffset: 200, recorded: 620), 620)
    }

    // MARK: - The Jump to latest button

    func testTheButtonIsHiddenAtTheBottom() {
        for distance in [CGFloat(0), ChatView.atBottomTolerance] {
            XCTAssertEqual(ChatView.jumpToLatest(distanceFromBottom: distance, messagesArrivedWhileAway: false),
                           .hidden, "distance \(distance)")
        }
    }

    func testAReaderScrolledUpWithNothingNewCanJump() {
        XCTAssertEqual(ChatView.jumpToLatest(distanceFromBottom: ChatView.atBottomTolerance.nextUp,
                                             messagesArrivedWhileAway: false), .jump)
        XCTAssertEqual(ChatView.jumpToLatest(distanceFromBottom: 400, messagesArrivedWhileAway: false), .jump)
    }

    func testMessagesArrivingBelowAScrolledUpReaderAreAnnounced() {
        XCTAssertEqual(ChatView.jumpToLatest(distanceFromBottom: 400, messagesArrivedWhileAway: true),
                       .newMessages)
    }

    /// Back at the bottom the reader sees what arrived, so the button goes.
    func testTheButtonIsHiddenBackAtTheBottomWhateverArrived() {
        for distance in [CGFloat(0), ChatView.atBottomTolerance, -120] {
            XCTAssertEqual(ChatView.jumpToLatest(distanceFromBottom: distance, messagesArrivedWhileAway: true),
                           .hidden, "distance \(distance)")
        }
    }

    // MARK: - The position a scroll report leaves behind

    /// A scroll up is taken down along with where it came from, and the count
    /// kept for a reader who left is still held while they are away.
    func testScrollingUpRecordsTheOffsetAndDistanceAndKeepsTheCountFromWhenYouLeft() {
        let away = MessageListPosition(lastOffset: 500, distanceFromBottom: 0, messageCountWhenLeft: 12)
            .recording(offset: 200, distanceFromBottom: 620)
        XCTAssertEqual(away, MessageListPosition(lastOffset: 200, distanceFromBottom: 620, messageCountWhenLeft: 12))
    }

    /// Back at the bottom there is no longer anyone away, so the count of
    /// messages from when they left goes — which is what hides "New messages".
    func testReachingTheBottomForgetsTheCountFromWhenYouLeft() {
        let back = MessageListPosition(lastOffset: 200, distanceFromBottom: 620, messageCountWhenLeft: 12)
            .recording(offset: 820, distanceFromBottom: 0)
        XCTAssertEqual(back, MessageListPosition(lastOffset: 820, distanceFromBottom: 0, messageCountWhenLeft: nil))
    }

    /// Content growing under a reader at the bottom moves nothing they would
    /// notice: they are still at the bottom, so the view's state is unchanged.
    func testContentArrivingUnderAReaderAtTheBottomLeavesThePositionAsItWas() {
        let atBottom = MessageListPosition(lastOffset: 500, distanceFromBottom: 0, messageCountWhenLeft: nil)
        XCTAssertEqual(atBottom.recording(offset: 500, distanceFromBottom: 320), atBottom)
    }
}
