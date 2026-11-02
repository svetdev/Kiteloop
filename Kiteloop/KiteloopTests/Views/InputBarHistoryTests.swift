import KiteloopCore
import XCTest
@testable import Kiteloop

/// What Up recalls is read off the conversation on screen: the human messages
/// that were typed into the field, in the order they were sent.
final class InputBarHistoryTests: XCTestCase {

    private func message(_ sender: Message.Sender, _ content: Message.Content) -> Message {
        Message(id: UUID(), timestamp: .now, sender: sender, content: content)
    }

    func testHumanTextIsKeptInTheOrderItWasSent() {
        let messages = [
            message(.human, .text("first")),
            message(.human, .text("second")),
            message(.human, .text("third"))
        ]
        XCTAssertEqual(InputBar.sentHistory(from: messages), ["first", "second", "third"])
    }

    func testAgentAndSystemMessagesAreSkipped() {
        let messages = [
            message(.human, .text("mine")),
            message(.agent("claude"), .text("theirs")),
            message(.system, .text("notice")),
            message(.human, .text("mine again"))
        ]
        XCTAssertEqual(InputBar.sentHistory(from: messages), ["mine", "mine again"])
    }

    func testHumanMessagesThatAreNotTextAreSkipped() {
        let messages = [
            message(.human, .image(Data([0x1]))),
            message(.human, .text("typed")),
            message(.human, .error("failed"))
        ]
        XCTAssertEqual(InputBar.sentHistory(from: messages), ["typed"])
    }

    func testAConversationWithNothingTypedRecallsNothing() {
        XCTAssertEqual(InputBar.sentHistory(from: []), [])
        XCTAssertEqual(InputBar.sentHistory(from: [message(.agent("claude"), .text("hello"))]), [])
    }
}
