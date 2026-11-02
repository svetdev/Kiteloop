import XCTest
@testable import KiteloopCore

final class AgentActivityDisplayTests: XCTestCase {

    private func subagent(status: AgentTaskStatus = .running, progress: AgentTaskProgress? = nil) -> AgentActivity.TaskState {
        var task = AgentActivity.TaskState(taskID: "t", toolUseID: "call", kind: .subagent,
                                           description: "List files", subagentType: "general-purpose")
        task.status = status
        task.progress = progress
        return task
    }

    private func shell(status: AgentTaskStatus = .running, summary: String? = nil) -> AgentActivity.TaskState {
        var task = AgentActivity.TaskState(taskID: "b", toolUseID: "bash", kind: .backgroundShell,
                                           description: "sleep", isBackgrounded: true)
        task.status = status
        task.summary = summary
        return task
    }

    // MARK: - Subagent status

    func testARunningSubagentReadsItsTypeCountersAndLastTool() {
        let task = subagent(progress: AgentTaskProgress(totalTokens: 16213, toolUses: 2, durationMs: 5745,
                                                        lastToolName: "Bash"))
        XCTAssertEqual(AgentActivityDisplay.statusLine(for: task),
                       "general-purpose · 2 tools · 16k tokens · last: Bash")
    }

    func testASubagentWithNoProgressYetIsStarting() {
        XCTAssertEqual(AgentActivityDisplay.statusLine(for: subagent()), "general-purpose · starting")
    }

    func testAFinishedSubagentSaysHowItEndedAndDropsTheLastTool() {
        let progress = AgentTaskProgress(totalTokens: 16499, toolUses: 1, lastToolName: "SubagentHandback")
        XCTAssertEqual(AgentActivityDisplay.statusLine(for: subagent(status: .completed, progress: progress)),
                       "general-purpose · completed · 1 tool · 16k tokens")
        XCTAssertEqual(AgentActivityDisplay.statusLine(for: subagent(status: .failed)), "general-purpose · failed")
        XCTAssertEqual(AgentActivityDisplay.statusLine(for: subagent(status: .killed)), "general-purpose · stopped")
    }

    func testTheFixturesSubagentReadsCompletedWithTwoTools() throws {
        let task = try XCTUnwrap(AgentActivityTests.folded().task(forToolUseID: AgentActivityTests.agentCallID))
        XCTAssertEqual(AgentActivityDisplay.statusLine(for: task), "general-purpose · completed · 2 tools · 16k tokens")
    }

    // MARK: - Background shell status

    func testABackgroundShellRunsInTheBackgroundUntilItsNoticeArrives() {
        XCTAssertEqual(AgentActivityDisplay.statusLine(for: shell()), "running in background")
        let summary = "Background command \"sleep\" completed (exit code 0)"
        XCTAssertEqual(AgentActivityDisplay.statusLine(for: shell(status: .completed, summary: summary)),
                       "finished · exit code 0")
        XCTAssertEqual(AgentActivityDisplay.statusLine(for: shell(status: .failed, summary: "failed (exit code 2)")),
                       "failed · exit code 2")
        XCTAssertEqual(AgentActivityDisplay.statusLine(for: shell(status: .completed)), "finished")
    }

    func testOnlyABashCallAskedToRunInTheBackgroundIsBackgrounded() {
        XCTAssertTrue(AgentActivityDisplay.isBackgroundedShell(tool: "Bash", input: ["run_in_background": true]))
        XCTAssertFalse(AgentActivityDisplay.isBackgroundedShell(tool: "Bash", input: ["run_in_background": false]))
        XCTAssertFalse(AgentActivityDisplay.isBackgroundedShell(tool: "Bash", input: [:]))
        XCTAssertFalse(AgentActivityDisplay.isBackgroundedShell(tool: "Agent", input: ["run_in_background": true]))
    }

    func testAgentAndTaskStartSubagents() {
        XCTAssertTrue(AgentActivityDisplay.startsSubagent(tool: "Agent"))
        XCTAssertTrue(AgentActivityDisplay.startsSubagent(tool: "Task"))
        XCTAssertFalse(AgentActivityDisplay.startsSubagent(tool: "Bash"))
    }

    func testCompactTokens() {
        XCTAssertEqual(AgentActivityDisplay.compactTokens(950), "950")
        XCTAssertEqual(AgentActivityDisplay.compactTokens(16213), "16k")
        XCTAssertEqual(AgentActivityDisplay.compactTokens(1_200_000), "1.2M")
    }

    // MARK: - Background strip

    func testTheBackgroundStripNamesWhatIsRunningAndIsGoneWhenNothingIs() {
        let tasks = [AgentActivityEvent.BackgroundTask(taskID: "b", kind: .backgroundShell, description: "Run the tests")]
        XCTAssertEqual(AgentActivityDisplay.backgroundSummary(tasks), "Background: 1 running · Run the tests")
        XCTAssertNil(AgentActivityDisplay.backgroundSummary([]))
    }

    // MARK: - Thinking

    func testEmptyThinkingReadsItsEstimate() {
        XCTAssertEqual(AgentActivityDisplay.thinkingLabel(text: "", estimatedTokens: 201), "Thinking… (201 tokens)")
        XCTAssertEqual(AgentActivityDisplay.thinkingLabel(text: "", estimatedTokens: nil), "Thinking…")
        XCTAssertTrue(AgentActivityDisplay.isBlankThinking(" \n"))
    }

    func testThinkingWithTextKeepsThePlainLabel() {
        XCTAssertEqual(AgentActivityDisplay.thinkingLabel(text: "Let me see", estimatedTokens: 201), "Thinking…")
        XCTAssertFalse(AgentActivityDisplay.isBlankThinking("Let me see"))
    }

    // MARK: - Rate limit

    private func limit(_ status: String, window: String? = "five_hour", utilization: Double? = 0.92) -> AgentActivityEvent.RateLimitInfo {
        .init(status: status, window: window, resetsAt: Date(timeIntervalSince1970: 0), utilization: utilization)
    }

    func testAnAllowedRateLimitSaysNothing() throws {
        let fixture = try XCTUnwrap(AgentActivityTests.folded().rateLimit)
        XCTAssertNil(AgentActivityDisplay.rateLimitNotice(previous: nil, current: fixture))
    }

    func testAWarningOrARefusalGetsOneLine() {
        XCTAssertEqual(AgentActivityDisplay.rateLimitNotice(previous: nil, current: limit("allowed_warning"),
                                                            resetTime: { _ in "3:00 PM" }),
                       "Approaching the rate limit (five-hour window) — 92% used, resets 3:00 PM")
        XCTAssertEqual(AgentActivityDisplay.rateLimitNotice(previous: limit("allowed_warning"),
                                                            current: limit("rejected", utilization: nil),
                                                            resetTime: { _ in "3:00 PM" }),
                       "Rate limit reached (five-hour window), resets 3:00 PM")
    }

    func testTheSameNoticeTwiceIsNotRepeated() {
        XCTAssertNil(AgentActivityDisplay.rateLimitNotice(previous: limit("allowed_warning"), current: limit("allowed_warning")))
        XCTAssertNotNil(AgentActivityDisplay.rateLimitNotice(previous: limit("allowed_warning"),
                                                             current: limit("allowed_warning", window: "seven_day")))
    }

    // MARK: - Nesting

    func testASubagentsCallsHangUnderItsAgentCallAndNotAtTheTop() {
        let agent = Message.toolCall(.init(id: "a", name: "Agent", input: "{}"), agent: "me")
        let bash = Message.toolCall(.init(id: "b", name: "Bash", input: "{}", parentToolUseID: "a"), agent: "me")
        let handback = Message.toolCall(.init(id: "h", name: "SubagentHandback", input: "{}", parentToolUseID: "a"), agent: "me")
        let own = Message.toolCall(.init(id: "c", name: "Read", input: "{}"), agent: "me")
        let messages = [agent, bash, .agentText("hi", agent: "me"), handback, own]

        XCTAssertEqual(messages.filter(ToolCallNesting.isTopLevel).map(\.id), [agent.id, messages[2].id, own.id])
        XCTAssertEqual(ToolCallNesting.children(in: messages)["a"]?.map(\.id), ["b", "h"])
        XCTAssertNil(ToolCallNesting.children(in: messages)["c"])
    }

    func testASubagentsTextAndThinkingHangUnderItsAgentCallWithItsCalls() {
        let agent = Message.toolCall(.init(id: "a", name: "Agent", input: "{}"), agent: "me")
        let bash = Message.toolCall(.init(id: "b", name: "Bash", input: "{}", parentToolUseID: "a"), agent: "me")
        let thought = Message.agentThinking("", agent: "me", parent: "a")
        let report = Message.agentText("two files", agent: "me", parent: "a")
        let own = Message.agentText("summary", agent: "me")
        let messages = [agent, bash, thought, report, own]

        XCTAssertEqual(messages.filter(ToolCallNesting.isTopLevel).map(\.id), [agent.id, own.id])
        XCTAssertEqual(ToolCallNesting.childMessages(in: messages)["a"]?.map(\.id), [bash.id, thought.id, report.id])
        XCTAssertEqual(ToolCallNesting.children(in: messages)["a"]?.map(\.id), ["b"], "calls alone, as before")
    }

    /// A message keeps its parent through a save, and one saved before
    /// parents were kept on text loads as the agent's own.
    func testATextsParentSurvivesASaveAndAnOldSaveLoadsWithout() throws {
        let saved = try JSONEncoder().encode(Message.agentText("two files", agent: "me", parent: "a"))
        XCTAssertEqual(try JSONDecoder().decode(Message.self, from: saved).parentToolUseID, "a")

        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        old.removeValue(forKey: "parentToolUseID")
        let loaded = try JSONDecoder().decode(Message.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertNil(loaded.parentToolUseID)
        XCTAssertTrue(ToolCallNesting.isTopLevel(loaded))
    }

    func testAToolCallSavedBeforeParentsWereKeptLoadsAsTopLevel() throws {
        let saved = #"{"id":"x","name":"Bash","input":"{}","isCollapsed":true}"#
        let call = try JSONDecoder().decode(Message.ToolCall.self, from: Data(saved.utf8))
        XCTAssertNil(call.parentToolUseID)
        let result = try JSONDecoder().decode(Message.ToolResult.self,
                                              from: Data(#"{"id":"r","toolCallID":"x","output":""}"#.utf8))
        XCTAssertNil(result.parentToolUseID)
    }

    func testAParentAndAThinkingEstimateSurviveASaveAndLoad() throws {
        let call = Message.toolCall(.init(id: "b", name: "Bash", input: "{}", parentToolUseID: "a"), agent: "me")
        let thought = Message.agentThinking("", agent: "me", estimatedTokens: 201)
        let decoded = try JSONDecoder().decode([Message].self, from: JSONEncoder().encode([call, thought]))
        guard case .toolCall(let loaded) = decoded[0].content else { return XCTFail("not a tool call") }
        XCTAssertEqual(loaded.parentToolUseID, "a")
        XCTAssertEqual(decoded[1].thinkingTokenEstimate, 201)
    }
}
