import XCTest
@testable import Kiteloop

/// The SESSIONS list highlights the chat that is open, not the newest one.
final class SidebarSessionHighlightTests: XCTestCase {

    private let newest = UUID()
    private let older = UUID()

    func testOpenSessionWinsOverTheFirst() {
        XCTAssertEqual(KiteloopSidebar.highlightedSessionID(open: older, in: [newest, older]), older)
    }

    func testNoOpenSessionFallsBackToTheFirst() {
        XCTAssertEqual(KiteloopSidebar.highlightedSessionID(open: nil, in: [newest, older]), newest)
    }

    func testUnknownOpenSessionFallsBackToTheFirst() {
        XCTAssertEqual(KiteloopSidebar.highlightedSessionID(open: UUID(), in: [newest, older]), newest)
    }

    func testNoSessionsHighlightsNothing() {
        XCTAssertNil(KiteloopSidebar.highlightedSessionID(open: older, in: []))
    }
}
