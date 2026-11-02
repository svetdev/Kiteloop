import SwiftUI
import XCTest
import KiteloopCore
@testable import Kiteloop

/// Which row the message list draws for a message: an agent's question, a plan
/// and an MCP server's request for keys are each their own card, and anything
/// else is an ordinary row. Read off the view `row(for:)` builds — the chosen
/// branch is the only one a `@ViewBuilder` result holds.
@MainActor
final class ChatViewRowTests: XCTestCase {
    private var list: MessageListContainer!

    override func setUp() async throws {
        let dir = try makeTemporaryDirectory(prefix: "chat-view-row")
        let orchestrator = Orchestrator(runtime: MockAgentRuntime())
        orchestrator.addAgent(Agent(
            id: "test", name: "Test", model: "sonnet",
            systemPrompt: "", tools: [],
            denied: [], permissionMode: "default", state: .idle
        ))
        let vm = ChatViewModel(agentID: "test", projectURL: dir, orchestrator: orchestrator)
        list = MessageListContainer(viewModel: vm, isTranscriptMode: false, isStreaming: false,
                                    lastCompletedDuration: nil, elapsedSeconds: 0)
    }

    private func row(_ content: Message.Content) -> Any {
        list.row(for: Message(id: UUID(), timestamp: .now, sender: .agent("test"), content: content),
                 results: [:], children: [:], showsCursor: false, terminal: false)
    }

    /// Whether `view` holds a `V` anywhere in its value.
    private func holds<V>(_ view: Any, _ type: V.Type) -> Bool {
        var pending: [Any] = [view]
        while let next = pending.popLast() {
            if next is V { return true }
            pending.append(contentsOf: Mirror(reflecting: next).children.map(\.value))
        }
        return false
    }

    func testAPlanIsDrawnAsItsCard() {
        let drawn = row(.plan(Message.PlanProposal(text: "# Plan\n\n1. Rewire it")))
        XCTAssertTrue(holds(drawn, PlanCard.self))
        XCTAssertFalse(holds(drawn, AskHumanBubble.self))
    }

    func testAnAgentsQuestionIsDrawnAsItsBubble() {
        let drawn = row(.approval(Message.ApprovalRequest(id: "q1", action: "Which branch?",
                                                          tool: "ask_human", status: .pending)))
        XCTAssertTrue(holds(drawn, AskHumanBubble.self))
        XCTAssertFalse(holds(drawn, PlanCard.self))
    }

    func testAServersRequestForKeysIsDrawnAsItsCard() {
        let drawn = row(.mcpAuthRequest(Message.MCPAuthRequest(
            id: "a1", toolCallID: "t1", serverName: "linear", reason: "needs a key",
            description: "Linear", authKeys: ["LINEAR_API_KEY"])))
        XCTAssertTrue(holds(drawn, MCPAuthorizationCard.self))
    }

    func testTextAndOtherApprovalsAreOrdinaryRows() {
        for content: Message.Content in [
            .text("Here is what I found."),
            .approval(Message.ApprovalRequest(id: "p1", action: "Run tests", tool: "Bash", status: .pending)),
        ] {
            let drawn = row(content)
            XCTAssertFalse(holds(drawn, PlanCard.self))
            XCTAssertFalse(holds(drawn, AskHumanBubble.self))
            XCTAssertFalse(holds(drawn, MCPAuthorizationCard.self))
        }
    }
}
