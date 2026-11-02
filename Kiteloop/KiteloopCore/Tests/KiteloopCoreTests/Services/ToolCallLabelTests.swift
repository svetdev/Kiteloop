import XCTest
@testable import KiteloopCore

/// The activity ticker and the transcript's tool rows used to print the
/// arguments of a call — forty or eighty characters of shell, cut mid-token —
/// while the sentence saying what the call was for sat unread in the same JSON
/// object. These assert that the sentence is what shows now, that a call
/// carrying none reads as it always did, and that the command is still on the
/// row beside it.
final class ToolCallLabelTests: XCTestCase {

    // MARK: - The transcript row

    func testRowSummaryPrefersTheDescription() {
        let summary = ToolCallLabel.rowSummary(tool: "Bash", input: [
            "command": "ls backlog 2>/dev/null | head; git branch -a | grep -i backlog",
            "description": "List the backlog items and the branches touching them"
        ])

        XCTAssertEqual(summary, "List the backlog items and the branches touching them")
    }

    func testRowSummaryFallsBackToTheCommand() {
        let summary = ToolCallLabel.rowSummary(tool: "Bash", input: ["command": "git status"])

        XCTAssertEqual(summary, "git status")
    }

    /// The row for a launched agent used to show a fragment of the tool
    /// *result* — boilerplate identical for every agent ever launched.
    func testRowSummaryForAnAgentIsItsDescription() {
        let summary = ToolCallLabel.rowSummary(tool: "Agent", input: [
            "description": "Fix knowledge-subordinate test failure",
            "prompt": "In the given worktree …"
        ])

        XCTAssertEqual(summary, "Fix knowledge-subordinate test failure")
    }

    func testRowSummaryLeavesOtherToolsAlone() {
        XCTAssertEqual(ToolCallLabel.rowSummary(tool: "Grep", input: ["pattern": "activityLabel"]),
                       "activityLabel")
        XCTAssertEqual(ToolCallLabel.rowSummary(tool: "Glob", input: ["pattern": "**/*.swift"]),
                       "**/*.swift")
        XCTAssertEqual(ToolCallLabel.rowSummary(tool: "message_agent",
                                                input: ["agent": "Reviewer", "message": "ready"]),
                       "@Reviewer: ready")
    }

    // MARK: - The one list both surfaces read

    /// The ticker used to carry a second, shorter list of its own, so a call
    /// the row named by its arguments showed there as nothing but the tool's
    /// name. There is one list now, and these are the arms it gained.
    func testArgumentSummaryNamesTheAgentAndTheBrowserCalls() {
        XCTAssertEqual(ToolCallLabel.argumentSummary(
            tool: "message_agent",
            input: ["agent": "Reviewer", "message": "the branch is ready"],
            widths: .ticker), "@Reviewer: the branch is ready")
        XCTAssertEqual(ToolCallLabel.argumentSummary(
            tool: "broadcast_agents",
            input: ["agents": ["Reviewer", "Scribe"], "message": "build is green"],
            widths: .ticker), "→ Reviewer, Scribe: build is green")
        XCTAssertEqual(ToolCallLabel.argumentSummary(
            tool: "web_navigate",
            input: ["url": "https://example.com/docs"],
            widths: .ticker), "https://example.com/docs")
    }

    /// The file arm is the one the ticker had and the row did not need: the row
    /// draws a file path itself and only asks for a summary when there is none.
    func testArgumentSummaryNamesAFileByItsLastPathComponent() {
        for tool in ["Read", "Edit", "Write"] {
            XCTAssertEqual(ToolCallLabel.argumentSummary(
                tool: tool, input: ["file_path": "/a/b/ChatViewModel.swift"], widths: .ticker),
                           "ChatViewModel.swift")
        }
        XCTAssertNil(ToolCallLabel.argumentSummary(tool: "Read", input: [:], widths: .ticker))
    }

    /// The list is shared; the widths are not. The ticker is one line beside a
    /// spinner, so it cuts a command and a pattern shorter than the row does.
    func testWidthsAreTheOnlyThingThatDiffersBetweenTheSurfaces() {
        let command = "cd Kiteloop && xcodebuild -project Kiteloop.xcodeproj -scheme Kiteloop build"
        let input: [String: Any] = ["command": command]

        XCTAssertEqual(ToolCallLabel.argumentSummary(tool: "Bash", input: input, widths: .ticker),
                       ToolCallLabel.shorten(command, limit: 40))
        XCTAssertEqual(ToolCallLabel.rowSummary(tool: "Bash", input: input),
                       ToolCallLabel.shorten(command, limit: 80))

        let pattern = String(repeating: "a", count: 50)
        XCTAssertEqual(ToolCallLabel.argumentSummary(tool: "Grep", input: ["pattern": pattern],
                                                     widths: .ticker),
                       String(pattern.prefix(30)))
        XCTAssertEqual(ToolCallLabel.rowSummary(tool: "Grep", input: ["pattern": pattern]), pattern)
    }

    /// A tool neither surface names keeps the bare row it has today.
    func testArgumentSummaryIsNilForAToolNeitherSurfaceNames() {
        XCTAssertNil(ToolCallLabel.argumentSummary(tool: "recall_knowledge",
                                                   input: ["query": "autopilot"], widths: .ticker))
        XCTAssertEqual(ToolCallLabel.rowSummary(tool: "recall_knowledge",
                                                input: ["query": "autopilot"]), "")
    }

    // MARK: - The pieces

    func testDescriptionIsReadOnlyForTheToolsThatCarryOne() {
        let input: [String: Any] = ["description": "something"]

        XCTAssertEqual(ToolCallLabel.description(tool: "Bash", input: input), "something")
        XCTAssertEqual(ToolCallLabel.description(tool: "Agent", input: input), "something")
        XCTAssertEqual(ToolCallLabel.description(tool: "Task", input: input), "something")
        XCTAssertNil(ToolCallLabel.description(tool: "Read", input: input))
        XCTAssertNil(ToolCallLabel.description(tool: "Grep", input: input))
    }

    func testDetailIsTheWholeCommandUntruncated() {
        let command = String(repeating: "echo hello; ", count: 20) + "echo done"
        let detail = ToolCallLabel.detail(tool: "Bash", input: ["command": command])

        XCTAssertEqual(detail, command)
        XCTAssertNil(ToolCallLabel.detail(tool: "Agent", input: ["prompt": "a page of text"]))
    }

    /// The expansion used to print the JSON the CLI sent, so a script read as
    /// one line with `\n` in it. These pin the command back to how it was run.
    func testExpansionTextIsTheCommandWithItsRealLineBreaks() {
        let command = "set -e\ncd Kiteloop\necho \"done\""
        let text = ToolCallLabel.expansionText(tool: "Bash", input: [
            "command": command,
            "description": "Build the app"
        ])

        XCTAssertEqual(text, command)
    }

    func testExpansionTextIsThePromptOfADelegatedCall() {
        XCTAssertEqual(ToolCallLabel.expansionText(tool: "Agent", input: ["prompt": "a page of text"]),
                       "a page of text")
        XCTAssertEqual(ToolCallLabel.expansionText(tool: "Task", input: ["prompt": "a page of text"]),
                       "a page of text")
    }

    /// A tool the function knows nothing about has no body worth preferring, so
    /// the row keeps expanding to exactly what it expands to today.
    func testExpansionTextIsNilForAToolItKnowsNothingAbout() {
        XCTAssertNil(ToolCallLabel.expansionText(tool: "Grep", input: ["pattern": "TODO"]))
        XCTAssertNil(ToolCallLabel.expansionText(tool: "Read", input: ["file_path": "/tmp/a.txt"]))
    }

    /// An empty or blank command is nothing to show — better the arguments than
    /// an empty box.
    func testExpansionTextIsNilForAnEmptyCommand() {
        XCTAssertNil(ToolCallLabel.expansionText(tool: "Bash", input: ["command": ""]))
        XCTAssertNil(ToolCallLabel.expansionText(tool: "Bash", input: ["command": "  \n "]))
        XCTAssertNil(ToolCallLabel.expansionText(tool: "Bash", input: ["description": "no command at all"]))
    }

    func testShortenLeavesTextThatFitsAlone() {
        XCTAssertEqual(ToolCallLabel.shorten("git status", limit: 40), "git status")
    }

    func testShortenCutsOnAWordBoundary() {
        XCTAssertEqual(ToolCallLabel.shorten("one two three four five", limit: 12), "one two…")
    }

    /// A single token longer than the whole budget has no boundary worth
    /// honouring — cutting at the last space would throw the row away.
    func testShortenCutsAnUnbrokenTokenWhereItLands() {
        XCTAssertEqual(ToolCallLabel.shorten("a /very/long/unbroken/path/segment", limit: 12),
                       "a /very/long…")
    }

    func testShortenFlattensRunsOfWhitespace() {
        XCTAssertEqual(ToolCallLabel.shorten("cd Kiteloop &&\n  xcodebuild", limit: 40),
                       "cd Kiteloop && xcodebuild")
    }
}
