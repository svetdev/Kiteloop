import XCTest
import KiteloopCore
@testable import Kiteloop

/// A SESSIONS row whose chat holds an unsent draft says so in its subtitle.
@MainActor
final class SidebarSessionDraftSubtitleTests: XCTestCase {

    private func subtitle(draft: String?) -> String {
        var session = ChatSession(agentID: "a", title: "Deploy")
        session.draft = draft
        return KiteloopSidebar.sessionSubtitle(for: session, lastMessageTime: "5 min. ago")
    }

    func testDraftShowsItsFirstLine() {
        XCTAssertEqual(subtitle(draft: "fix the build\nand then deploy"), "Draft: fix the build")
    }

    func testBlankLeadingLinesAreSkipped() {
        XCTAssertEqual(subtitle(draft: "\n   \n  fix the build  \nand then deploy"), "Draft: fix the build")
    }

    func testNoDraftShowsTheLastMessageTime() {
        XCTAssertEqual(subtitle(draft: nil), "5 min. ago")
    }

    func testEmptyDraftShowsTheLastMessageTime() {
        XCTAssertEqual(subtitle(draft: ""), "5 min. ago")
    }

    func testWhitespaceOnlyDraftShowsTheLastMessageTime() {
        XCTAssertEqual(subtitle(draft: " \n\t\n  "), "5 min. ago")
    }
}
