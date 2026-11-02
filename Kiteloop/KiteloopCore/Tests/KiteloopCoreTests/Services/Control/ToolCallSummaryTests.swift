import XCTest
@testable import KiteloopCore

/// The transcript endpoint's one line per tool call: the name and what the
/// tool was pointed at, never the raw input, never a bare name when the input
/// had something to say.
final class ToolCallSummaryTests: XCTestCase {

    func testBashPrefersItsDescriptionOverTheCommand() {
        let input = #"{"command": "git status --short | head", "description": "Show working tree status"}"#
        XCTAssertEqual(ToolCallSummary.line(name: "Bash", input: input), "Bash — Show working tree status")
    }

    func testBashWithoutADescriptionShowsTheCommandsFirstLine() {
        let input = #"{"command": "cd Kiteloop && xcodebuild build\n  -quiet"}"#
        XCTAssertEqual(ToolCallSummary.line(name: "Bash", input: input), "Bash — cd Kiteloop && xcodebuild build")
    }

    func testAFileToolKeepsTheLastTwoPathComponents() {
        let input = #"{"file_path": "/Users/x/kiteloop/Kiteloop/Kiteloop/Services/WorktreeManager.swift", "old_string": "a", "new_string": "b"}"#
        XCTAssertEqual(ToolCallSummary.line(name: "Edit", input: input), "Edit — Services/WorktreeManager.swift")
        XCTAssertEqual(ToolCallSummary.line(name: "Read", input: #"{"file_path": "CLAUDE.md"}"#), "Read — CLAUDE.md")
    }

    func testSearchesShowThePatternAndAgentsTheirTask() {
        XCTAssertEqual(ToolCallSummary.line(name: "Grep", input: #"{"pattern": "func runSetupCommand", "path": "Kiteloop"}"#),
                       "Grep — func runSetupCommand")
        XCTAssertEqual(ToolCallSummary.line(name: "Agent", input: #"{"description": "Find the stall watchdog", "prompt": "…"}"#),
                       "Agent — Find the stall watchdog")
    }

    func testALongSummaryIsCutWithAnEllipsisAndWhitespaceCollapsed() {
        let command = String(repeating: "word ", count: 40)
        let line = ToolCallSummary.line(name: "Bash", input: #"{"command": "\#(command)"}"#)
        XCTAssertTrue(line.hasPrefix("Bash — word word"), line)
        XCTAssertTrue(line.hasSuffix("…"), line)
        XCTAssertLessThanOrEqual(line.count, "Bash — ".count + ToolCallSummary.maxLength, line)
    }

    func testAnUnknownToolOrANonJSONInputKeepsTheNameAlone() {
        XCTAssertEqual(ToolCallSummary.line(name: "mcp__kiteloop__send_message", input: #"{"to": "planner"}"#),
                       "mcp__kiteloop__send_message")
        XCTAssertEqual(ToolCallSummary.line(name: "Bash", input: "not json"), "Bash")
        XCTAssertEqual(ToolCallSummary.line(name: "Bash", input: #"{"command": "   \n"}"#), "Bash")
    }
}
