import XCTest
@testable import KiteloopCore

/// `AgentActivityEvent` and `AgentActivity` against a stream the CLI really
/// wrote: `claude` 2.1.281 asked to multiply, list files through a subagent and
/// run a shell in the background, captured with `--output-format stream-json
/// --verbose --include-hook-events` and sanitized.
final class AgentActivityTests: XCTestCase {

    static let agentCallID = "toolu_01RRgdR6YB5fCRQe3GK3hZ8A"
    static let backgroundCallID = "toolu_019XTqpLMCQiLwhBGP7wGzhZ"

    /// The fixture, one decoded object per line.
    static func fixtureLines() throws -> [[String: Any]] {
        let url = RepositoryRoot.of().appending(
            path: "Kiteloop/KiteloopCore/Tests/Fixtures/stream-json/cli-2.1.281-subagent-background-thinking.jsonl")
        let text = try String(contentsOf: url, encoding: .utf8)
        return try text.split(separator: "\n").map { line in
            let object = try JSONSerialization.jsonObject(with: Data(line.utf8))
            return try XCTUnwrap(object as? [String: Any], "not an object: \(line.prefix(80))")
        }
    }

    static func fixtureEvents() throws -> [AgentActivityEvent] {
        try fixtureLines().compactMap(AgentActivityEvent.parse(json:))
    }

    static func folded() throws -> AgentActivity {
        var activity = AgentActivity()
        try fixtureEvents().forEach { activity.apply($0) }
        return activity
    }

    // MARK: - Parsing

    func testEveryLineDecodesAndOnlyActivityLinesYieldEvents() throws {
        let lines = try Self.fixtureLines()
        XCTAssertEqual(lines.count, 34)
        let kinds = lines.compactMap(AgentActivityEvent.parse(json:)).map(Self.name)
        XCTAssertEqual(kinds, [
            "thinking", "thinking", "rateLimit",
            "started", "progress", "progress", "updated", "notification",
            "background", "started",
            "background", "updated", "notification",
        ])
    }

    func testSystemSubtypesItDoesNotReadAreIgnoredNotErrors() {
        for subtype in ["hook_started", "hook_response", "init", "compact_boundary", "some_future_subtype"] {
            XCTAssertNil(AgentActivityEvent.parse(subtype: subtype, payload: ["type": "system", "subtype": subtype]))
        }
        XCTAssertNil(AgentActivityEvent.parse(json: ["type": "assistant"]))
    }

    func testALineMissingWhatItsSubtypeNeedsYieldsNothing() {
        XCTAssertNil(AgentActivityEvent.parse(subtype: "task_started", payload: [:]))
        XCTAssertNil(AgentActivityEvent.parse(subtype: "task_notification", payload: ["task_id": "t"]))
        XCTAssertNil(AgentActivityEvent.parse(subtype: "rate_limit_event", payload: [:]))
    }

    func testTaskStartedReadsEveryField() throws {
        let started = try Self.fixtureEvents().compactMap { event -> AgentActivityEvent.TaskStarted? in
            if case .taskStarted(let started) = event { return started }
            return nil
        }
        XCTAssertEqual(started.first, AgentActivityEvent.TaskStarted(
            taskID: "ada637d5b066e64ba", toolUseID: Self.agentCallID, kind: .subagent,
            description: "List files in cwd", subagentType: "general-purpose", isBackgrounded: false))
        XCTAssertEqual(started.last?.kind, .backgroundShell)
        XCTAssertEqual(started.last?.isBackgrounded, true)
    }

    func testTheSubagentsOwnLinesCarryTheAgentCallAsParentAndTheMainAgentsDoNot() throws {
        let lines = try Self.fixtureLines()
        let subagentToolUses = lines.filter { line in
            guard line["type"] as? String == "assistant",
                  let content = (line["message"] as? [String: Any])?["content"] as? [[String: Any]] else { return false }
            return content.contains { $0["type"] as? String == "tool_use" } && StreamLineage.parentToolUseID(in: line) != nil
        }
        XCTAssertEqual(subagentToolUses.count, 2, "the subagent's Bash and SubagentHandback calls")
        XCTAssertTrue(subagentToolUses.allSatisfy { StreamLineage.parentToolUseID(in: $0) == Self.agentCallID })
        // The main agent's lines say `null`, which must read as no parent.
        XCTAssertNil(StreamLineage.parentToolUseID(in: lines[7]))
        XCTAssertNil(StreamLineage.parentToolUseID(in: ["parent_tool_use_id": NSNull()]))
    }

    // MARK: - Folding

    func testTheAgentCallsTaskGoesFromStartedThroughProgressToCompleted() throws {
        let events = try Self.fixtureEvents()
        var activity = AgentActivity()
        var statuses: [AgentTaskStatus] = []
        for event in events {
            activity.apply(event)
            if let task = activity.task(forToolUseID: Self.agentCallID), statuses.last != task.status {
                statuses.append(task.status)
            }
        }
        XCTAssertEqual(statuses, [.running, .completed])

        let task = try XCTUnwrap(activity.task(forToolUseID: Self.agentCallID))
        XCTAssertEqual(task.kind, .subagent)
        XCTAssertEqual(task.subagentType, "general-purpose")
        XCTAssertEqual(task.description, "List files in cwd")
        XCTAssertEqual(task.progress?.toolUses, 2)
        XCTAssertEqual(task.progress?.lastToolName, "SubagentHandback",
                       "the closing notice names no tool, and must not erase the last one")
        XCTAssertEqual(task.progress?.totalTokens, 16499, "the notice's final count")
        XCTAssertEqual(task.outputFile, "/tmp/fixture")
    }

    func testMidwayTheSubagentReportsItsFirstTool() throws {
        let events = try Self.fixtureEvents()
        var activity = AgentActivity()
        for event in events {
            activity.apply(event)
            if case .taskProgress = event { break }
        }
        let task = try XCTUnwrap(activity.task(forToolUseID: Self.agentCallID))
        XCTAssertEqual(task.status, .running)
        XCTAssertEqual(task.progress, AgentTaskProgress(totalTokens: 14236, toolUses: 1, durationMs: 2314,
                                                        lastToolName: "Bash"))
    }

    func testTheBackgroundShellIsListedThenLeavesTheListAndCompletes() throws {
        var activity = AgentActivity()
        var listings: [[String]] = []
        for event in try Self.fixtureEvents() {
            activity.apply(event)
            if case .backgroundTasksChanged = event { listings.append(activity.backgroundTasks.map(\.taskID)) }
        }
        XCTAssertEqual(listings, [["bjhve0mu5"], []])
        let shell = try XCTUnwrap(activity.task(forToolUseID: Self.backgroundCallID))
        XCTAssertEqual(shell.kind, .backgroundShell)
        XCTAssertTrue(shell.isBackgrounded)
        XCTAssertEqual(shell.status, .completed)
        XCTAssertEqual(AgentActivityDisplay.exitCode(in: shell.summary), 0)
    }

    func testTheThinkingEstimateEndsAt201AndIsClaimedOnce() throws {
        var activity = try Self.folded()
        XCTAssertEqual(activity.thinkingTokens, 201)
        XCTAssertEqual(activity.takeThinkingEstimate(), 201)
        XCTAssertNil(activity.takeThinkingEstimate(), "the next thinking block does not inherit it")
    }

    func testTheRateLimitNoticeIsKept() throws {
        let info = try XCTUnwrap(Self.folded().rateLimit)
        XCTAssertEqual(info.status, "allowed")
        XCTAssertEqual(info.window, "five_hour")
        XCTAssertEqual(info.utilization, 0.05)
        XCTAssertEqual(info.resetsAt, Date(timeIntervalSince1970: 1_790_352_000))
    }

    func testAnUpdateForATaskNotYetStartedIsKeptAndCompletedByItsStart() {
        var activity = AgentActivity()
        activity.apply(.taskUpdated(taskID: "t1", status: .killed))
        activity.apply(.taskStarted(.init(taskID: "t1", toolUseID: "call", kind: .backgroundShell,
                                          description: "serve", subagentType: nil, isBackgrounded: true)))
        XCTAssertEqual(activity.task(forToolUseID: "call")?.status, .killed)
        XCTAssertEqual(activity.task(forToolUseID: "call")?.description, "serve")
    }

    func testStatusesTheCLISpellsAreRead() {
        XCTAssertEqual(AgentTaskStatus("completed"), .completed)
        XCTAssertEqual(AgentTaskStatus("failed"), .failed)
        XCTAssertEqual(AgentTaskStatus("killed"), .killed)
        XCTAssertEqual(AgentTaskStatus("pending"), .running)
        XCTAssertEqual(AgentTaskStatus("paused"), .other("paused"))
        XCTAssertFalse(AgentTaskStatus.running.isFinished)
        XCTAssertTrue(AgentTaskStatus.other("paused").isFinished)
    }

    private static func name(_ event: AgentActivityEvent) -> String {
        switch event {
        case .taskStarted: return "started"
        case .taskProgress: return "progress"
        case .taskUpdated: return "updated"
        case .taskNotification: return "notification"
        case .backgroundTasksChanged: return "background"
        case .thinkingTokens: return "thinking"
        case .rateLimit: return "rateLimit"
        }
    }
}
