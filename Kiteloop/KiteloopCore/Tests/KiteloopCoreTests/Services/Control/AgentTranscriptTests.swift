import XCTest
@testable import KiteloopCore

/// What an agent events stream sends: each message once when it is new, again
/// when what it flattens to changes, and nothing for a change the phone cannot
/// see.
final class AgentTranscriptTests: XCTestCase {

    private func text(_ body: String, from sender: Message.Sender = .agent("Builder"), id: UUID = UUID()) -> Message {
        Message(id: id, timestamp: Date(timeIntervalSince1970: 0), sender: sender, content: .text(body))
    }

    func testAStreamStartingFromNowSendsOnlyWhatArrivesLater() {
        let old = [text("hi", from: .human), text("hello")]
        var tracker = AgentTranscript.Tracker(messages: old, after: nil)

        XCTAssertTrue(tracker.changes(in: old).isEmpty)
        let new = text("more")
        let changes = tracker.changes(in: old + [new])
        XCTAssertEqual(changes.map { $0["id"] as? String }, [new.id.uuidString])
    }

    func testAReplyStillStreamingIsSentAgainUnderItsIDEachTimeItGrows() {
        let id = UUID()
        var tracker = AgentTranscript.Tracker(messages: [], after: nil)

        XCTAssertEqual(tracker.changes(in: [text("Found", id: id)]).first?["text"] as? String, "Found")
        XCTAssertEqual(tracker.changes(in: [text("Found it", id: id)]).first?["text"] as? String, "Found it")
        XCTAssertTrue(tracker.changes(in: [text("Found it", id: id)]).isEmpty, "unchanged sends nothing")
    }

    func testAfterSendsEverythingPastThatMessage() {
        let messages = [text("one"), text("two"), text("three")]
        var tracker = AgentTranscript.Tracker(messages: messages, after: messages[0].id)

        XCTAssertEqual(tracker.changes(in: messages).compactMap { $0["text"] as? String }, ["two", "three"])
    }

    func testAnAfterTheChatDoesNotHoldSendsTheWholeWindow() {
        let messages = [text("one"), text("two")]
        var tracker = AgentTranscript.Tracker(messages: messages, after: UUID())

        XCTAssertEqual(tracker.changes(in: messages).count, 2)
    }

    func testAMessageThatFlattensToNothingIsNeverSent() {
        let empty = text("")
        var tracker = AgentTranscript.Tracker(messages: [], after: nil)

        XCTAssertTrue(tracker.changes(in: [empty]).isEmpty)
    }

    func testTheTailIsTheNewestMessagesOldestFirst() {
        let messages = (1...5).map { text("m\($0)") }

        XCTAssertEqual(AgentTranscript.tail(of: messages, limit: 2).compactMap { $0["text"] as? String }, ["m4", "m5"])
    }

    // MARK: - Cards the phone answers

    func testAnOpenPlanFlattensWithItsTextAndOpen() throws {
        let msg = Message(id: UUID(), timestamp: .now, sender: .agent("Planner"),
                          content: .plan(Message.PlanProposal(text: "1. Do it")))

        let flat = try XCTUnwrap(AgentTranscript.message(msg))

        XCTAssertEqual(flat["kind"] as? String, "plan")
        XCTAssertEqual(flat["text"] as? String, "1. Do it")
        XCTAssertEqual((flat["plan"] as? [String: Any])?["open"] as? Bool, true)
    }

    func testAnsweringAPlanIsAChangeTheStreamSends() {
        let id = UUID()
        func plan(_ answer: Message.PlanProposal.Answer?) -> Message {
            Message(id: id, timestamp: .now, sender: .agent("Planner"),
                    content: .plan(Message.PlanProposal(text: "1. Do it", answer: answer)))
        }
        var tracker = AgentTranscript.Tracker(messages: [plan(nil)], after: nil)

        let changes = tracker.changes(in: [plan(.approveAuto)])

        XCTAssertEqual((changes.first?["plan"] as? [String: Any])?["answer"] as? String, "approveAuto")
    }

    func testAnAskHumanQuestionFlattensWithItsRequest() throws {
        let msg = Message(id: UUID(), timestamp: .now, sender: .agent("Builder"),
                          content: .approval(Message.ApprovalRequest(id: "tool-7", action: "Keep the old rounding?", tool: "ask_human")))

        let flat = try XCTUnwrap(AgentTranscript.message(msg))

        XCTAssertEqual(flat["kind"] as? String, "question")
        XCTAssertEqual(flat["text"] as? String, "Keep the old rounding?")
        XCTAssertEqual((flat["question"] as? [String: Any])?["request"] as? String, "tool-7")
        XCTAssertEqual((flat["question"] as? [String: Any])?["open"] as? Bool, true)
    }

    func testAFileToolCarriesItsWholePath() throws {
        let call = Message.ToolCall(id: "t1", name: "Edit", input: #"{"file_path":"/Users/me/project/src/ledger/refund.ts"}"#)
        let msg = Message(id: UUID(), timestamp: .now, sender: .agent("Builder"), content: .toolCall(call))

        let flat = try XCTUnwrap(AgentTranscript.message(msg))

        XCTAssertEqual(flat["path"] as? String, "/Users/me/project/src/ledger/refund.ts")
        let bash = Message(id: UUID(), timestamp: .now, sender: .agent("Builder"),
                           content: .toolCall(Message.ToolCall(id: "t2", name: "Bash", input: #"{"command":"ls"}"#)))
        XCTAssertNil(AgentTranscript.message(bash)?["path"])
    }

    func testAnApprovalForAnotherToolStaysOut() {
        let msg = Message(id: UUID(), timestamp: .now, sender: .agent("Builder"),
                          content: .approval(Message.ApprovalRequest(id: "t", action: "rm -rf", tool: "Bash")))

        XCTAssertNil(AgentTranscript.message(msg))
    }
}
