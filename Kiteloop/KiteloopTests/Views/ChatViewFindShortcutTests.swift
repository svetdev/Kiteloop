import XCTest
@testable import Kiteloop

/// What Cmd-F answers in each state the chat can be in. The key is bound once,
/// in `ChatView.body`'s background, so it fires over the bubble list, the
/// transcript and the empty chat alike — and only the bubble list can mark and
/// scroll to a match, which is why the transcript is left on the way in.
final class ChatViewFindShortcutTests: XCTestCase {

    func testFindOverTheBubbleListOpensTheBar() {
        XCTAssertEqual(
            ChatView.findShortcutAction(isTranscriptMode: false, isSearching: false),
            .openBar
        )
    }

    func testFindOverAnOpenBarClosesIt() {
        XCTAssertEqual(
            ChatView.findShortcutAction(isTranscriptMode: false, isSearching: true),
            .closeBar
        )
        XCTAssertEqual(
            ChatView.findShortcutAction(isTranscriptMode: true, isSearching: true),
            .closeBar
        )
    }

    func testFindOverTheTranscriptLeavesTranscriptModeFirst() {
        XCTAssertEqual(
            ChatView.findShortcutAction(isTranscriptMode: true, isSearching: false),
            .leaveTranscriptAndOpenBar
        )
    }
}
