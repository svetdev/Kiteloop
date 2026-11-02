import XCTest
import KiteloopCore
@testable import Kiteloop

/// Coverage for the Autopilot console's transcript shaping — the rules that turn
/// a raw message stream into `Verb(target)` rows. The load-bearing assertions are
/// that a tool result stops being a row of its own and becomes the line under the
/// call that produced it, and that a burst of consecutive shell calls is one row.
final class AutopilotTranscriptTests: XCTestCase {

    // MARK: - Fixtures

    private func text(_ body: String, from sender: Message.Sender = .agent("worker")) -> Message {
        Message(id: UUID(), timestamp: Date(), sender: sender, content: .text(body))
    }

    private func toolCall(_ id: String, _ name: String, _ input: [String: Any]) -> Message {
        let json = String(
            data: try! JSONSerialization.data(withJSONObject: input),
            encoding: .utf8
        )!
        return Message(id: UUID(), timestamp: Date(), sender: .agent("worker"),
                       content: .toolCall(Message.ToolCall(id: id, name: name, input: json)))
    }

    private func toolResult(_ callID: String, _ output: String) -> Message {
        Message(id: UUID(), timestamp: Date(), sender: .agent("worker"),
                content: .toolResult(Message.ToolResult(
                    id: UUID().uuidString, toolCallID: callID, output: output)))
    }

    private func bash(_ id: String, _ command: String) -> Message {
        toolCall(id, "Bash", ["command": command])
    }

    private func calls(_ row: AutopilotTranscript.Row?) -> [AutopilotTranscript.Call] {
        switch row?.kind {
        case .call(let call): return [call]
        case .shell(let calls): return calls
        default: return []
        }
    }

    private func isProse(_ row: AutopilotTranscript.Row?) -> Bool {
        if case .prose = row?.kind { return true }
        return false
    }

    // MARK: - Row shaping

    /// A call and its result are one row: the headline names the action and the
    /// target, the dimmed line under it is what came back.
    func testToolResultBecomesTheLineUnderItsCall() {
        let transcript = AutopilotTranscript.make(from: [
            toolCall("t1", "Read", ["file_path": "/repo/Kiteloop/Views/AutopilotView.swift"]),
            toolResult("t1", (1...12).map { "line \($0)" }.joined(separator: "\n")),
        ])

        XCTAssertEqual(transcript.rows.count, 1, "The result is not a row of its own")
        let call = calls(transcript.rows.first).first
        XCTAssertEqual(call?.headline, "Read(AutopilotView.swift)")
        XCTAssertEqual(call?.result, "Read 12 lines")
        XCTAssertEqual(call?.isError, false)
    }

    /// A call still in flight has a headline and no result line yet — the row
    /// must not claim an outcome it doesn't have.
    func testCallWithoutAResultHasNoResultLine() {
        let transcript = AutopilotTranscript.make(from: [toolCall("t1", "Read", ["file_path": "a.swift"])])

        XCTAssertNil(calls(transcript.rows.first).first?.result)
        XCTAssertEqual(calls(transcript.rows.first).first?.isError, false)
        XCTAssertNil(calls(transcript.rows.first).first?.output, "A call in flight has nothing to unfold")
    }

    /// A failed build's result line is its first line, shortened; the call still
    /// keeps everything it returned, so the row can unfold to the reason.
    func testCallKeepsItsWholeOutputBesideTheResultLine() {
        let error = """
            error: /repo/Kiteloop/Views/Backlog/AutopilotTranscriptView.swift:42:17: cannot find 'ActivityOutput' in scope; did you mean 'ActivityResult'?
                            ActivityOutput(text: output, isError: call.isError)
                            ^~~~~~~~~~~~~~
            ** BUILD FAILED **
            """
        let transcript = AutopilotTranscript.make(from: [
            bash("t1", "xcodebuild build-for-testing"),
            toolResult("t1", error),
        ])

        let call = calls(transcript.rows.first).first
        XCTAssertEqual(call?.output, error)
        XCTAssertEqual(call?.isError, true)
        XCTAssertEqual(call?.result, AutopilotTranscript.resultLine(tool: "Bash", input: [:], output: error))
        XCTAssertTrue(call?.result?.hasSuffix("…") ?? false, "The result line is still the shortened first line")
        XCTAssertFalse(call?.result?.contains("BUILD FAILED") ?? true)
    }

    // MARK: - Unfolded output

    func testCappedOutputWithinTheLimitIsUnchanged() {
        let output = "one\ntwo\nthree"

        XCTAssertEqual(AutopilotTranscript.cappedOutput(output, limit: 5), output)
        XCTAssertEqual(AutopilotTranscript.cappedOutput(output, limit: 3), output, "Exactly at the cap is unchanged")
    }

    func testCappedOutputOverTheLimitCountsTheRest() {
        let output = (1...10).map { "line \($0)" }.joined(separator: "\n")

        XCTAssertEqual(AutopilotTranscript.cappedOutput(output, limit: 3), "line 1\nline 2\nline 3\n… +7 lines")
        XCTAssertEqual(AutopilotTranscript.cappedOutput(output, limit: 9),
                       (1...9).map { "line \($0)" }.joined(separator: "\n") + "\n… +1 line")
    }

    /// Thinking stays out of the pane, and so does the message kind that draws
    /// nothing in it — it used to reach the list and render an empty row.
    func testThinkingAndAuthAreNotRows() {
        let transcript = AutopilotTranscript.make(from: [
            Message(id: UUID(), timestamp: Date(), sender: .agent("w"), content: .thinking("hmm")),
            Message(id: UUID(), timestamp: Date(), sender: .agent("w"),
                    content: .mcpAuthRequest(Message.MCPAuthRequest(
                        id: "m", toolCallID: "t", serverName: "s", reason: "why",
                        description: "d", authKeys: []))),
            text("Building now."),
        ])

        XCTAssertEqual(transcript.rows.count, 1)
        XCTAssertTrue(isProse(transcript.rows.first))
    }

    /// An approval is only worth a row while it's still waiting on someone.
    func testOnlyPendingApprovalsAreRows() {
        func approval(_ status: Message.ApprovalRequest.ApprovalStatus) -> Message {
            Message(id: UUID(), timestamp: Date(), sender: .agent("w"),
                    content: .approval(Message.ApprovalRequest(
                        id: "a", action: "merge", tool: "Bash", status: status)))
        }

        XCTAssertEqual(AutopilotTranscript.make(from: [approval(.pending)]).rows.count, 1)
        XCTAssertTrue(AutopilotTranscript.make(from: [approval(.approved)]).rows.isEmpty)
    }

    // MARK: - Shell grouping

    /// The row this reshaping exists for: a burst of shell calls is one row, not
    /// one per command, and it keeps every command inside it.
    func testConsecutiveShellCallsBecomeOneRow() {
        let transcript = AutopilotTranscript.make(from: [
            bash("b1", "git checkout -b work"),
            toolResult("b1", "Switched to a new branch"),
            bash("b2", "swift build"),
            toolResult("b2", "Compiling…\nBuild complete"),
            bash("b3", "git status"),
            toolResult("b3", "nothing to commit"),
        ])

        XCTAssertEqual(transcript.rows.count, 1)
        let group = calls(transcript.rows.first)
        XCTAssertEqual(group.map(\.id), ["b1", "b2", "b3"])
        XCTAssertEqual(AutopilotTranscript.shellHeadline(group), "Bash(3 commands)")
    }

    /// Prose between two commands ends the burst — the agent stopping to explain
    /// itself is exactly the boundary a reader is looking for.
    func testProseBreaksAShellBurst() {
        let transcript = AutopilotTranscript.make(from: [
            bash("b1", "swift build"),
            text("Build failed, retrying."),
            bash("b2", "swift build"),
            bash("b3", "swift test"),
        ])

        XCTAssertEqual(transcript.rows.count, 3)
        XCTAssertEqual(calls(transcript.rows[0]).map(\.id), ["b1"])
        XCTAssertTrue(isProse(transcript.rows[1]))
        XCTAssertEqual(calls(transcript.rows[2]).map(\.id), ["b2", "b3"], "The burst resumes as one row")
    }

    /// Only shell calls fold together; a file edge between two commands is its
    /// own row, and doesn't get swallowed by the burst around it.
    func testNonShellCallsAreNotGrouped() {
        let transcript = AutopilotTranscript.make(from: [
            bash("b1", "swift build"),
            toolCall("t1", "Read", ["file_path": "a.swift"]),
            bash("b2", "swift build"),
        ])

        XCTAssertEqual(transcript.rows.map { calls($0).map(\.id) }, [["b1"], ["t1"], ["b2"]])
    }

    /// The group's identity is its first command, so a burst that grows while it
    /// is on screen doesn't restart its expansion state.
    func testGrowingBurstKeepsItsRowIdentity() {
        let first = AutopilotTranscript.make(from: [bash("b1", "a"), bash("b2", "b")])
        let later = AutopilotTranscript.make(from: [bash("b1", "a"), bash("b2", "b"), bash("b3", "c")])

        XCTAssertEqual(first.rows.first?.id, "b1")
        XCTAssertEqual(later.rows.first?.id, "b1")
    }

    /// A failure is the reason to open a collapsed burst, so it outranks both the
    /// command running now and the last one that finished.
    func testCollapsedBurstLeadsWithFailures() {
        let transcript = AutopilotTranscript.make(from: [
            bash("b1", "swift build"),
            toolResult("b1", "Error: no such module"),
            bash("b2", "swift build"),
            toolResult("b2", "Build complete"),
        ])

        XCTAssertEqual(AutopilotTranscript.shellSummary(calls(transcript.rows.first)), "1 of 2 failed")
    }

    /// With nothing failed, the summary reports what's in flight, then falls back
    /// to the last thing that finished.
    func testCollapsedBurstReportsRunningThenLastResult() {
        let running = AutopilotTranscript.make(from: [
            bash("b1", "swift build"),
            toolResult("b1", "Build complete"),
            bash("b2", "swift test"),
        ])
        XCTAssertEqual(AutopilotTranscript.shellSummary(calls(running.rows.first)), "running swift test")

        let finished = AutopilotTranscript.make(from: [
            bash("b1", "swift build"),
            toolResult("b1", "Build complete"),
            bash("b2", "swift test"),
            toolResult("b2", "12 tests passed"),
        ])
        XCTAssertEqual(AutopilotTranscript.shellSummary(calls(finished.rows.first)), "12 tests passed")
    }

    // MARK: - Verbs

    /// The headline names the action, not the tool that performed it.
    func testVerbsReadAsActions() {
        XCTAssertEqual(AutopilotTranscript.verb(for: "Edit"), "Update")
        XCTAssertEqual(AutopilotTranscript.verb(for: "MultiEdit"), "Update")
        XCTAssertEqual(AutopilotTranscript.verb(for: "Grep"), "Search")
        XCTAssertEqual(AutopilotTranscript.verb(for: "Glob"), "Search")
        XCTAssertEqual(AutopilotTranscript.verb(for: "Read"), "Read")
        XCTAssertEqual(AutopilotTranscript.verb(for: "Bash"), "Bash")
    }

    /// An unmapped tool — every Kiteloop and MCP one — reads sensibly without
    /// having to be listed.
    func testUnmappedToolsFallBackToAReadableName() {
        XCTAssertEqual(AutopilotTranscript.verb(for: "publish_event"), "Publish Event")
        XCTAssertEqual(AutopilotTranscript.verb(for: "mcp__kiteloop-tools__message_agent"), "Message Agent")
    }

    // MARK: - Targets

    /// A file is its basename: the pane is 280pt at its narrowest and the
    /// directory is the half that repeats.
    func testFileTargetIsTheBasename() {
        XCTAssertEqual(
            AutopilotTranscript.target(tool: "Edit", input: ["file_path": "/a/b/AutopilotView.swift"]),
            "AutopilotView.swift")
    }

    /// A long or wrapped command is flattened to one line and truncated — a
    /// heredoc would otherwise be several hundred characters of headline.
    func testLongCommandsAreFlattenedAndTruncated() {
        let target = AutopilotTranscript.target(
            tool: "Bash",
            input: ["command": "xcodebuild -project Kiteloop.xcodeproj \\\n  -scheme Kiteloop -destination \"platform=macOS\" build"])

        XCTAssertFalse(target.contains("\n"))
        XCTAssertTrue(target.hasSuffix("…"))
        XCTAssertLessThanOrEqual(target.count, 49)
    }

    /// A tool with nothing to name gets a bare verb rather than empty parens.
    func testHeadlineWithoutATargetIsTheBareVerb() {
        let call = AutopilotTranscript.Call(
            id: "t", tool: "TodoWrite", verb: "Update Todos", target: "", result: nil, isError: false)

        XCTAssertEqual(call.headline, "Update Todos")
    }

    // MARK: - Result lines

    /// Where a count is the answer, the line is the count: nobody needs the first
    /// line of a file they can already see was read.
    func testResultsAreCountedWhereACountIsTheAnswer() {
        XCTAssertEqual(
            AutopilotTranscript.resultLine(tool: "Read", input: [:], output: "a\nb\nc"),
            "Read 3 lines")
        XCTAssertEqual(
            AutopilotTranscript.resultLine(tool: "Grep", input: [:], output: "a.swift\nb.swift"),
            "Found 2 matches")
        XCTAssertEqual(
            AutopilotTranscript.resultLine(tool: "Grep", input: [:], output: ""),
            "No matches found")
        XCTAssertEqual(
            AutopilotTranscript.resultLine(tool: "Glob", input: [:], output: "a.swift"),
            "Found 1 file")
    }

    /// An edit's result is its shape — the tool's own output is boilerplate.
    func testEditResultReportsTheDiffShape() {
        XCTAssertEqual(
            AutopilotTranscript.resultLine(
                tool: "Edit",
                input: ["old_string": "a", "new_string": "x\ny\nz"],
                output: "The file has been updated."),
            "Updated · 3 additions, 1 removal")
        XCTAssertEqual(
            AutopilotTranscript.resultLine(
                tool: "Write", input: ["content": "a\nb"], output: "File created."),
            "Wrote 2 lines")
    }

    /// Everything else gets the head of its output plus how much it stands in
    /// for, and a command that printed nothing says so rather than nothing.
    func testOtherResultsShowTheHeadOfTheOutput() {
        XCTAssertEqual(
            AutopilotTranscript.resultLine(tool: "Bash", input: [:], output: "first\nsecond\nthird"),
            "first  +2 lines")
        XCTAssertEqual(
            AutopilotTranscript.resultLine(tool: "Bash", input: [:], output: "only"),
            "only")
        XCTAssertEqual(
            AutopilotTranscript.resultLine(tool: "Bash", input: [:], output: "   \n  "),
            "(no output)")
    }

    /// A failure shows what failed, not a count of the lines it failed over.
    func testFailedCallsShowTheirError() {
        let transcript = AutopilotTranscript.make(from: [
            bash("b1", "swift build"),
            toolResult("b1", "Error: no such module 'Highlightr'\n…and 40 more lines"),
        ])

        let call = calls(transcript.rows.first).first
        XCTAssertEqual(call?.isError, true)
        XCTAssertEqual(call?.result, "Error: no such module 'Highlightr'")
    }

    /// Prefix-anchored on purpose: a build log that merely mentions the word
    /// "error" in passing hasn't failed, and this decides whether a row is red.
    func testErrorDetectionIsAnchored() {
        XCTAssertTrue(AutopilotTranscript.isError("error: build failed"))
        XCTAssertTrue(AutopilotTranscript.isError("<tool_use_error>no such file"))
        XCTAssertFalse(AutopilotTranscript.isError("0 errors, 3 warnings"))
    }

    // MARK: - Windowing

    /// The cap counts rows, so a burst that collapsed eleven commands into one
    /// row costs one row of the budget rather than eleven.
    func testCapCountsRowsNotMessages() {
        var messages: [Message] = [text("start")]
        for i in 0..<20 { messages.append(bash("b\(i)", "echo \(i)")) }

        let transcript = AutopilotTranscript.make(from: messages, limit: 5)

        XCTAssertEqual(transcript.rows.count, 2, "20 commands are one row, after the prose")
        XCTAssertEqual(transcript.hiddenRowCount, 0)
    }

    /// Past the cap the newest rows are the ones kept, and the pane is told how
    /// many it is standing in for.
    func testOldestRowsAreDroppedFirst() {
        let messages = (0..<8).map { text("message \($0)") }

        let transcript = AutopilotTranscript.make(from: messages, limit: 3)

        XCTAssertEqual(transcript.rows.count, 3)
        XCTAssertEqual(transcript.hiddenRowCount, 5)
        XCTAssertEqual(transcript.rows.map(\.id), messages.suffix(3).map(\.id.uuidString))
    }

    /// What the pane scrolls on. A visible count stops rising at the cap, so a
    /// run that scrolled itself for its first sixty rows would stop following the
    /// rest of the run — the total keeps climbing.
    func testTotalRowCountKeepsClimbingPastTheCap() {
        let messages = (0..<8).map { text("message \($0)") }

        XCTAssertEqual(AutopilotTranscript.make(from: messages, limit: 3).totalRowCount, 8)
        XCTAssertEqual(AutopilotTranscript.make(from: Array(messages.prefix(6)), limit: 3).totalRowCount, 6)
    }

    /// "Show N earlier" adds one page above the rows already shown, revealing at
    /// most what is hidden, and there is no button once nothing is.
    func testEarlierPageAddsOnePageOfHiddenRows() {
        let full = AutopilotTranscript.earlierPage(limit: 60, hiddenRowCount: 90)
        XCTAssertEqual(full?.nextLimit, 120)
        XCTAssertEqual(full?.revealed, 60)

        let partial = AutopilotTranscript.earlierPage(limit: 120, hiddenRowCount: 30)
        XCTAssertEqual(partial?.nextLimit, 150)
        XCTAssertEqual(partial?.revealed, 30)

        XCTAssertNil(AutopilotTranscript.earlierPage(limit: 150, hiddenRowCount: 0))
    }

    /// 150 rows: the newest 60 and "Show 60 earlier", then 120 and "Show 30
    /// earlier", then all 150 and no button — while the total the pane follows
    /// the stream on stays the same throughout.
    func testShowingEarlierRowsWalksBackToTheStartOfTheRun() {
        let messages = (0..<150).map { text("message \($0)") }
        var limit = AutopilotTranscript.defaultRowLimit
        var shown: [Int] = []
        var labels: [Int] = []

        while true {
            let transcript = AutopilotTranscript.make(from: messages, limit: limit)
            shown.append(transcript.rows.count)
            XCTAssertEqual(transcript.totalRowCount, 150)
            guard let page = AutopilotTranscript.earlierPage(
                limit: limit, hiddenRowCount: transcript.hiddenRowCount) else { break }
            labels.append(page.revealed)
            limit = page.nextLimit
        }

        XCTAssertEqual(shown, [60, 120, 150])
        XCTAssertEqual(labels, [60, 30])
        XCTAssertEqual(AutopilotTranscript.make(from: messages, limit: limit).rows.first?.id,
                       messages.first?.id.uuidString)
    }
}
