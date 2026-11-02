import XCTest
import KiteloopCore
@testable import Kiteloop

/// Delete Chat in the sidebar asks before it acts, and the question names the
/// chat by the title its row shows and says its messages go with it.
final class SidebarDeleteChatConfirmationTests: XCTestCase {

    func testMessageNamesTheChat() {
        let session = ChatSession(agentID: "a", title: "Fix the login bug")
        XCTAssertTrue(KiteloopSidebar.deleteChatMessage(for: session).contains("Fix the login bug"))
    }

    func testAnUntitledChatIsNamedNewChat() {
        let session = ChatSession(agentID: "a", title: "")
        XCTAssertTrue(KiteloopSidebar.deleteChatMessage(for: session).contains("“New Chat”"))
    }

    func testMessageSaysTheMessagesAreDeleted() {
        let session = ChatSession(agentID: "a", title: "Fix the login bug")
        XCTAssertTrue(KiteloopSidebar.deleteChatMessage(for: session).contains("all of its messages"))
    }
}
