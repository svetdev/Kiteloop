import XCTest
@testable import KiteloopCore

final class MessageTests: XCTestCase {

    /// A tool call starts collapsed: the transcript shows the call and hides its
    /// input until someone opens it. That is the init's default, which is what
    /// the app constructs with.
    func testAToolCallIsCollapsedUnlessAskedOtherwise() {
        let call = Message.ToolCall(id: "call-1", name: "Read", input: "{\"path\":\"a.swift\"}")
        XCTAssertTrue(call.isCollapsed)
        XCTAssertNil(call.output)

        let opened = Message.ToolCall(id: "call-2", name: "Read", input: "{}", isCollapsed: false)
        XCTAssertFalse(opened.isCollapsed)
    }

}

final class MessagePlanProposalCodingTests: XCTestCase {

    private func roundTrip(_ message: Message) throws -> Message {
        try JSONDecoder().decode(Message.self, from: JSONEncoder().encode(message))
    }

    /// An answered card reloads showing which choice was made.
    func testAnAnsweredPlanCardKeepsItsAnswerAcrossASave() throws {
        let card = Message(id: UUID(), timestamp: .now, sender: .agent("a"),
                           content: .plan(Message.PlanProposal(text: "# Plan", answer: .approveAcceptEdits)))
        guard case .plan(let plan) = try roundTrip(card).content else { return XCTFail("Expected a plan card") }
        XCTAssertEqual(plan.text, "# Plan")
        XCTAssertEqual(plan.answer, .approveAcceptEdits)
    }

    func testAPlanCardSavedWithoutAnAnswerLoadsUnanswered() throws {
        let json = ##"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","timestamp":0,"sender":{"type":"agent","agentID":"a"},"content":{"type":"plan","plan":{"text":"# Plan"}}}"##
        let message = try JSONDecoder().decode(Message.self, from: Data(json.utf8))
        guard case .plan(let plan) = message.content else { return XCTFail("Expected a plan card") }
        XCTAssertEqual(plan.text, "# Plan")
        XCTAssertNil(plan.answer)
    }

    /// A chat saved before plan cards existed decodes as it always did.
    func testAChatSavedBeforePlanCardsLoadsUnchanged() throws {
        let json = ##"[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","timestamp":0,"sender":{"type":"human"},"content":{"type":"text","value":"hi"}},{"id":"7F9619FF-8B86-D011-B42D-00C04FC964FF","timestamp":1,"sender":{"type":"agent","agentID":"a"},"content":{"type":"toolCall","toolCall":{"id":"c","name":"Write","input":"{}","isCollapsed":true}}}]"##
        let messages = try JSONDecoder().decode([Message].self, from: Data(json.utf8))
        XCTAssertEqual(messages.count, 2)
        guard case .text(let text) = messages[0].content else { return XCTFail("Expected text") }
        XCTAssertEqual(text, "hi")
        guard case .toolCall(let call) = messages[1].content else { return XCTFail("Expected a tool call") }
        XCTAssertEqual(call.name, "Write")
    }
}
