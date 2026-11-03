import XCTest
import KiteloopCore
@testable import Kiteloop

/// Transcript mode prints a subagent's calls under the `Agent` call that made
/// them, not at their place in the stream among the main agent's own.
final class TranscriptViewSubagentOrderTests: XCTestCase {
    private let agentCall = Message.ToolCall(id: "a", name: "Agent", input: "{}")

    private func call(_ id: String, parent: String?) -> Message {
        .toolCall(.init(id: id, name: "Bash", input: "{}", parentToolUseID: parent), agent: "me")
    }

    private func ids(_ order: [(message: Message, depth: Int)]) -> [String] {
        order.map { entry in
            switch entry.message.content {
            case .toolCall(let call): return "\(call.id)@\(entry.depth)"
            case .toolResult(let result): return "r-\(result.toolCallID)@\(entry.depth)"
            case .text(let text): return "\(text)@\(entry.depth)"
            default: return "?"
            }
        }
    }

    func testASubagentsCallsPrintIndentedUnderItsAgentCallAndNowhereElse() {
        let messages: [Message] = [
            .toolCall(agentCall, agent: "me"),
            call("own", parent: nil),
            call("b", parent: "a"),
            .toolResult(.init(id: "rb", toolCallID: "b", output: "ok", parentToolUseID: "a"), agent: "me"),
            call("c", parent: "a"),
            .agentText("done", agent: "me"),
        ]
        XCTAssertEqual(ids(TranscriptView.transcriptOrder(messages)),
                       ["a@0", "b@1", "r-b@1", "c@1", "own@0", "done@0"])
    }

    func testAConversationWithNoSubagentsPrintsAsBefore() {
        let messages: [Message] = [call("x", parent: nil), .agentText("hi", agent: "me"), call("y", parent: nil)]
        XCTAssertEqual(ids(TranscriptView.transcriptOrder(messages)), ["x@0", "hi@0", "y@0"])
    }

    func testAChildWhoseParentIsNotInTheListIsKeptWhereItCame() {
        let messages: [Message] = [call("x", parent: nil), call("orphan", parent: "gone")]
        XCTAssertEqual(ids(TranscriptView.transcriptOrder(messages)), ["x@0", "orphan@0"])
    }
}
