import XCTest
@testable import Kiteloop

/// A notice's body in the bell popover: two lines while the row is folded,
/// every line once it is opened. It used to be cut to two lines with nothing
/// to reveal the rest — a store error's reason sat past the file path.
final class NotificationBodyLineLimitTests: XCTestCase {

    func testAFoldedNoticeShowsTwoLines() {
        XCTAssertEqual(NotificationListView.bodyLineLimit(isExpanded: false), 2)
    }

    func testAnExpandedNoticeShowsEveryLine() {
        XCTAssertNil(NotificationListView.bodyLineLimit(isExpanded: true))
    }
}
