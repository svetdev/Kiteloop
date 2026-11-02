import KiteloopCore
import XCTest
@testable import Kiteloop

/// What a chat row's copy button copies, which both the bubble and the
/// terminal look ask the same helper: the whole text of a message you sent
/// or of an agent's reply, and nothing for a row that offers no copy.
final class MessageCopyTextTests: XCTestCase {

    private func message(_ sender: Message.Sender, _ content: Message.Content) -> Message {
        Message(id: UUID(), timestamp: Date(), sender: sender, content: content)
    }

    func testAMessageYouSentCopiesItsFullText() {
        let prompt = "Refactor the parser.\n\nKeep the public API as it is."
        XCTAssertEqual(MessageBubble.copyableText(of: message(.human, .text(prompt))), prompt)
    }

    func testAnAgentsReplyCopiesItsFullText() {
        let reply = "Done — **three** files changed."
        XCTAssertEqual(MessageBubble.copyableText(of: message(.agent("coder"), .text(reply))), reply)
    }

    func testASystemNoteOffersNoCopy() {
        XCTAssertNil(MessageBubble.copyableText(of: message(.system, .text("Session restarted"))))
    }

    func testAnErrorOffersNoCopy() {
        XCTAssertNil(MessageBubble.copyableText(of: message(.agent("coder"), .error("Process exited"))))
    }

    func testAToolCallOffersNoCopy() {
        let call = Message.ToolCall(id: "call-1", name: "Read", input: "{}")
        XCTAssertNil(MessageBubble.copyableText(of: message(.agent("coder"), .toolCall(call))))
    }

    func testAnImageOffersNoCopy() {
        XCTAssertNil(MessageBubble.copyableText(of: message(.human, .image(Data([0x89, 0x50])))))
    }
}
