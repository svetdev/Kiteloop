import XCTest
@testable import Kiteloop

/// What each key typed into the Web Preview's "Find on page" field does — the
/// same three the chat's own find bar answers to.
final class WebPreviewFindKeyTests: XCTestCase {

    func testReturnSearchesForward() {
        XCTAssertEqual(WebPreviewPanel.findKeyAction(for: .returnKey), .next)
    }

    func testShiftReturnSearchesBackward() {
        XCTAssertEqual(WebPreviewPanel.findKeyAction(for: .shiftReturn), .previous)
    }

    func testEscapeClosesTheRow() {
        XCTAssertEqual(WebPreviewPanel.findKeyAction(for: .escape), .close)
    }
}
