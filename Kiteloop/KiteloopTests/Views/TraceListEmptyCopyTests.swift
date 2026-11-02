import XCTest
@testable import Kiteloop

/// A Traces pane with no recorded session says why its list is empty, and its
/// detail pane stops sending you to pick from that empty list.
final class TraceListEmptyCopyTests: XCTestCase {

    func testNoSessionsTheSidebarSaysWhatFillsIt() throws {
        let copy = try XCTUnwrap(TraceListView.sidebarEmptyCopy(hasSessions: false))
        XCTAssertEqual(copy.title, "No turns recorded yet")
        XCTAssertEqual(copy.message, "A session appears here once an agent answers a message in this project.")
    }

    func testWithSessionsTheSidebarShowsTheList() {
        XCTAssertNil(TraceListView.sidebarEmptyCopy(hasSessions: true))
    }

    func testNoSessionsTheDetailPaneDoesNotPointAtTheList() {
        let copy = TraceListView.detailEmptyCopy(hasSessions: false)
        XCTAssertEqual(copy.title, "Nothing to show yet")
        XCTAssertFalse(copy.message.contains("on the left"))
        XCTAssertFalse(copy.message.lowercased().contains("choose"))
    }

    func testWithSessionsTheDetailPaneAsksForAChoice() {
        let copy = TraceListView.detailEmptyCopy(hasSessions: true)
        XCTAssertEqual(copy.title, "No session selected")
        XCTAssertEqual(copy.message, "Choose a session on the left to see its cost, tokens, and duration per turn.")
    }
}
