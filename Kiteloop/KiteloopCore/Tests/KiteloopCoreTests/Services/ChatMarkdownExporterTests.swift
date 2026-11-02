import XCTest
@testable import KiteloopCore

/// Export Chat…'s Markdown: each message headed by its sender and time, every
/// shown content case rendered, and thinking and access-card values never written.
final class ChatMarkdownExporterTests: XCTestCase {

    private let utc = TimeZone(identifier: "UTC")!

    private func message(_ sender: Message.Sender, _ content: Message.Content, at seconds: TimeInterval = 0) -> Message {
        Message(id: UUID(), timestamp: Date(timeIntervalSince1970: seconds), sender: sender, content: content)
    }

    private func export(_ messages: [Message]) -> String {
        ChatMarkdownExporter.markdown(
            title: "Release plan",
            messages: messages,
            agentName: { $0 == "dev-1" ? "Ada" : $0 },
            timeZone: utc
        )
    }

    func testMessagesAreHeadedBySenderAndTimeInOrder() {
        let output = export([
            message(.human, .text("First question"), at: 0),
            message(.agent("dev-1"), .text("First answer"), at: 60),
            message(.system, .text("A note"), at: 120),
        ])
        XCTAssertTrue(output.hasPrefix("# Release plan\n"))
        let you = output.range(of: "### You — 1970-01-01 00:00\n\nFirst question")
        let ada = output.range(of: "### Ada — 1970-01-01 00:01\n\nFirst answer")
        let system = output.range(of: "### System — 1970-01-01 00:02\n\nA note")
        XCTAssertNotNil(you)
        XCTAssertNotNil(ada)
        XCTAssertNotNil(system)
        XCTAssertLessThan(you!.lowerBound, ada!.lowerBound)
        XCTAssertLessThan(ada!.lowerBound, system!.lowerBound)
    }

    func testAnAgentIsNamedNotIdentified() {
        let output = export([message(.agent("dev-1"), .text("hi"))])
        XCTAssertTrue(output.contains("### Ada"))
        XCTAssertFalse(output.contains("dev-1"))
    }

    func testEveryShownContentCaseIsRendered() {
        let output = export([
            message(.agent("dev-1"), .text("Plain text in full")),
            message(.agent("dev-1"), .error("Rate limited, retry later")),
            message(.agent("dev-1"), .toolCall(Message.ToolCall(id: "t1", name: "Bash", input: "ls -la", output: "secret listing"))),
            message(.human, .image(Data([0x89, 0x50]))),
            message(.system, .systemEvent(Message.SystemEvent(kind: .compaction, detail: "Context compacted"))),
        ])
        XCTAssertTrue(output.contains("Plain text in full"))
        XCTAssertTrue(output.contains("**Error:** Rate limited, retry later"))
        XCTAssertTrue(output.contains("- Tool call: `Bash`"))
        XCTAssertFalse(output.contains("ls -la"), "a tool call is one line naming the tool")
        XCTAssertFalse(output.contains("secret listing"))
        XCTAssertTrue(output.contains("_[image]_"))
        XCTAssertTrue(output.contains("_Context compacted_"))
    }

    func testThinkingAndAccessCardValuesAreNeverWritten() {
        let card = Message.MCPAuthRequest(
            id: "a1", toolCallID: "t1", serverName: "github", reason: "needs token",
            description: "GitHub access", authKeys: ["GITHUB_TOKEN"], status: .authorized,
            envValues: ["GITHUB_TOKEN": "ghp_supersecret"]
        )
        let output = export([
            message(.agent("dev-1"), .thinking("private reasoning")),
            message(.agent("dev-1"), .mcpAuthRequest(card)),
            message(.agent("dev-1"), .toolResult(Message.ToolResult(id: "r1", toolCallID: "t1", output: "raw result"))),
            message(.agent("dev-1"), .approval(Message.ApprovalRequest(id: "p1", action: "rm -rf build", tool: "Bash"))),
        ])
        XCTAssertFalse(output.contains("private reasoning"))
        XCTAssertFalse(output.contains("ghp_supersecret"))
        XCTAssertFalse(output.contains("GITHUB_TOKEN"))
        XCTAssertFalse(output.contains("raw result"))
        XCTAssertFalse(output.contains("rm -rf build"))
        XCTAssertEqual(output, "# Release plan\n", "left-out content gets no heading either")
    }

    func testTheFileNameIsTheTitleOrNewChat() {
        XCTAssertEqual(ChatMarkdownExporter.fileName(for: ChatSession(agentID: "a", title: "Release plan")), "Release plan.md")
        XCTAssertEqual(ChatMarkdownExporter.fileName(for: ChatSession(agentID: "a")), "New Chat.md")
        XCTAssertEqual(ChatMarkdownExporter.fileName(for: ChatSession(agentID: "a", title: "")), "New Chat.md")
    }
}
