import XCTest
import KiteloopCore
@testable import Kiteloop

/// What the chat's rows say about a subagent's calls, a task's status and an
/// empty thinking block, in both looks.
final class SubagentCallRowsTests: XCTestCase {

    private let agentCall = Message.ToolCall(id: "a", name: "Agent", input: #"{"description":"List files in cwd"}"#)
    private let childCall = Message.ToolCall(id: "b", name: "Bash",
                                             input: #"{"command":"ls -la /tmp/fixture","description":"List all files"}"#,
                                             parentToolUseID: "a")

    func testAChildCallPrintsTheWayTheAgentsOwnCallsDo() {
        XCTAssertEqual(SubagentRowText.childLine(for: childCall), "Bash(List all files)")
        XCTAssertEqual(SubagentRowText.childLine(for: .init(id: "x", name: "SubagentHandback", input: "{}")),
                       "SubagentHandback")
    }

    func testAnOpenedChildReadReadsAsItsLineCount() {
        let read = Message.ToolCall(id: "r", name: "Read", input: #"{"file_path":"/tmp/a.swift"}"#, parentToolUseID: "a")
        let output = (1...84).map { "line \($0)" }.joined(separator: "\n")
        let result = Message.ToolResult(id: "o", toolCallID: "r", output: output, parentToolUseID: "a")
        XCTAssertEqual(SubagentRowText.openedLines(for: read, result: result), ["Read 84 lines"])
    }

    func testAnOpenedChildThatFailedReadsAsItsError() {
        let output = "Error: ENOENT: no such file or directory\nat line 2"
        let result = Message.ToolResult(id: "o", toolCallID: "b", output: output, parentToolUseID: "a")
        XCTAssertTrue(ToolResultOutcome.of(output: output).isError)
        XCTAssertEqual(SubagentRowText.openedLines(for: childCall, result: result), ["Error: ENOENT: no such file or directory"])
    }

    func testAnOpenedChildWithNoResultIsStillRunning() {
        XCTAssertEqual(SubagentRowText.openedLines(for: childCall, result: nil), ["Running…"])
    }

    func testFoldedChildrenReadAsACount() {
        XCTAssertEqual(SubagentRowText.foldedLine(count: 2), "+2 tool calls (click to expand)")
        XCTAssertEqual(SubagentRowText.foldedLine(count: 1), "+1 tool call (click to expand)")
    }

    func testARowWithNoTaskFallsBackToItsResult() {
        XCTAssertNil(SubagentRowText.statusLine(for: nil))
    }

    func testATasksOutcomeTintsItsRow() {
        var task = AgentActivity.TaskState(taskID: "t", kind: .subagent)
        XCTAssertEqual(SubagentRowText.outcome(of: task), .pending)
        task.status = .completed
        XCTAssertEqual(SubagentRowText.outcome(of: task), .success)
        task.status = .killed
        XCTAssertEqual(SubagentRowText.outcome(of: task), .failure)
    }

    func testChildrenArePairedWithTheirResultsUnderTheirParent() {
        let messages: [Message] = [
            .toolCall(agentCall, agent: "me"),
            .toolCall(childCall, agent: "me"),
            .toolResult(.init(id: "r", toolCallID: "b", output: "total 48", parentToolUseID: "a"), agent: "me"),
        ]
        let results = ["b": Message.ToolResult(id: "r", toolCallID: "b", output: "total 48", parentToolUseID: "a")]
        let nested = SubagentChild.byParent(in: messages, results: results)
        XCTAssertEqual(nested["a"]?.map(\.id), ["b"])
        XCTAssertEqual(nested["a"]?.first?.result?.output, "total 48")
    }

    /// What the subagent said and thought hangs under its call with its calls,
    /// in the order it came, and the list draws none of it at the top.
    func testASubagentsTextAndThinkingAreChildrenOfItsCallNotRowsOfTheirOwn() {
        let thought = Message.agentThinking("", agent: "me", estimatedTokens: 12, parent: "a")
        let report = Message.agentText("two files", agent: "me", parent: "a")
        let messages: [Message] = [.toolCall(agentCall, agent: "me"), .toolCall(childCall, agent: "me"), thought, report,
                                   .agentText("the agent's own summary", agent: "me")]
        let children = SubagentChild.byParent(in: messages, results: [:])["a"] ?? []
        XCTAssertEqual(children.map(\.id), ["b", thought.id.uuidString, report.id.uuidString])
        guard case .thinking(_, let estimate) = children[1].kind, case .text(let text) = children[2].kind else {
            return XCTFail("expected the thought, then the text")
        }
        XCTAssertEqual(estimate, 12)
        XCTAssertEqual(text, "two files")

        XCTAssertFalse(ChatView.shouldDisplay(thought))
        XCTAssertFalse(ChatView.shouldDisplay(report))
        XCTAssertTrue(ChatView.shouldDisplay(messages[4]))
    }

    func testFoldedChildrenCountWhatTheSubagentSaidBesideItsCalls() {
        XCTAssertEqual(SubagentRowText.foldedLine(count: 2, said: 1), "+2 tool calls, 1 message (click to expand)")
        XCTAssertEqual(SubagentRowText.summary(calls: 5, said: 0), "5 tool calls")
        let children = SubagentChild.byParent(in: [.toolCall(childCall, agent: "me"),
                                                   .agentText("done", agent: "me", parent: "a")], results: [:])["a"] ?? []
        XCTAssertTrue(SubagentRowText.counts(of: children) == (calls: 1, said: 1))
        XCTAssertEqual(SubagentRowText.thinkingLine("", estimatedTokens: 40), "Thinking… (40 tokens)")
    }

    func testTheMessageListDrawsOnlyTheAgentsOwnCalls() {
        XCTAssertTrue(ChatView.shouldDisplay(.toolCall(agentCall, agent: "me")))
        XCTAssertFalse(ChatView.shouldDisplay(.toolCall(childCall, agent: "me")))
    }

    func testTheTranscriptsThinkingLineReadsTheEstimateWhenTheTextIsEmpty() {
        XCTAssertEqual(TranscriptView.thinkingPreview("", estimatedTokens: 201), "Thinking… (201 tokens)")
        XCTAssertEqual(TranscriptView.thinkingPreview("Let me\nsee", estimatedTokens: 201), "Let me see")
    }

    /// A thinking block is drawn in the chat: its row reads "Thinking… (N
    /// tokens)" when the model returned no text, which is every current model.
    func testAThinkingBlockIsDrawnInTheChat() {
        let thinking = Message(id: UUID(), timestamp: Date(), sender: .agent("coder"), content: .thinking(""))
        XCTAssertTrue(ChatView.shouldDisplay(thinking))
    }
}
