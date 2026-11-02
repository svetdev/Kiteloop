import XCTest
@testable import Kiteloop

/// Remove Agent in the sidebar asks before it acts, and the question names the
/// agent and says what removing it does: it leaves this project's team.
final class SidebarRemoveAgentConfirmationTests: XCTestCase {

    func testMessageNamesTheAgent() {
        let message = KiteloopSidebar.removeAgentMessage(name: "Data Analyst")
        XCTAssertTrue(message.contains("Data Analyst"))
    }

    func testMessageSaysTheAgentLeavesTheTeam() {
        let message = KiteloopSidebar.removeAgentMessage(name: "Reviewer")
        XCTAssertTrue(message.contains("from this project's team"))
    }

    func testMessageSaysTheSessionStops() {
        let message = KiteloopSidebar.removeAgentMessage(name: "Reviewer")
        XCTAssertTrue(message.contains("Stops the live session"))
    }
}
