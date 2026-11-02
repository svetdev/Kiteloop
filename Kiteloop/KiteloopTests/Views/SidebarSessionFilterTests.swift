import XCTest
import KiteloopCore
@testable import Kiteloop

/// The SESSIONS filter narrows the list to chats whose shown title matches.
@MainActor
final class SidebarSessionFilterTests: XCTestCase {

    private let deploy = ChatSession(agentID: "a", title: "Fix the Deploy script")
    private let login = ChatSession(agentID: "a", title: "Login bug")
    private let untitled = ChatSession(agentID: "a", title: "")

    private var all: [ChatSession] { [deploy, login, untitled] }

    func testBlankQueryKeepsEverySessionInOrder() {
        XCTAssertEqual(KiteloopSidebar.filteredSessions(all, query: "").map(\.id), all.map(\.id))
    }

    func testWhitespaceQueryKeepsEverySessionInOrder() {
        XCTAssertEqual(KiteloopSidebar.filteredSessions(all, query: "  \n\t ").map(\.id), all.map(\.id))
    }

    func testQueryMatchesAnywhereInTheTitleIgnoringCase() {
        XCTAssertEqual(KiteloopSidebar.filteredSessions(all, query: "deploy").map(\.id), [deploy.id])
    }

    func testQueryIsTrimmedBeforeMatching() {
        XCTAssertEqual(KiteloopSidebar.filteredSessions(all, query: "  BUG ").map(\.id), [login.id])
    }

    func testUntitledSessionMatchesAsNewChat() {
        XCTAssertEqual(KiteloopSidebar.filteredSessions(all, query: "new chat").map(\.id), [untitled.id])
    }

    func testNoMatchLeavesNothing() {
        XCTAssertTrue(KiteloopSidebar.filteredSessions(all, query: "zebra").isEmpty)
    }

    func testMatchesKeepTheirOrder() {
        XCTAssertEqual(KiteloopSidebar.filteredSessions(all, query: "i").map(\.id), [deploy.id, login.id])
    }

    func testFilteredOutOpenChatLeavesNoShownRowHighlighted() {
        let highlighted = KiteloopSidebar.highlightedSessionID(open: login.id, in: all.map(\.id))
        let shown = KiteloopSidebar.filteredSessions(all, query: "deploy")
        XCTAssertEqual(highlighted, login.id)
        XCTAssertFalse(shown.contains { $0.id == highlighted })
    }

    func testFilterFieldNeedsMoreThanOneChat() {
        XCTAssertFalse(KiteloopSidebar.showsSessionFilter(for: []))
        XCTAssertFalse(KiteloopSidebar.showsSessionFilter(for: [deploy]))
        XCTAssertTrue(KiteloopSidebar.showsSessionFilter(for: [deploy, login]))
    }

    func testOneChatIsShownDespiteALeftoverQuery() {
        XCTAssertEqual(KiteloopSidebar.shownSessions([deploy], query: "zebra").map(\.id), [deploy.id])
    }

    func testNoChatsShowNothingDespiteALeftoverQuery() {
        XCTAssertTrue(KiteloopSidebar.shownSessions([], query: "zebra").isEmpty)
    }

    func testQueryStillNarrowsMoreThanOneChat() {
        XCTAssertEqual(KiteloopSidebar.shownSessions(all, query: "deploy").map(\.id), [deploy.id])
        XCTAssertTrue(KiteloopSidebar.shownSessions(all, query: "zebra").isEmpty)
    }
}
