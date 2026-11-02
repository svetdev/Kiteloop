import Foundation

/// What the chat says about a subagent, a background shell, the model's
/// thinking and the rate limit — the words, kept apart from the views that
/// draw them so both looks read the same and a test can assert them.
package enum AgentActivityDisplay {

    /// The tools whose call starts a subagent. `Task` is `Agent` under the
    /// other name the CLI uses for it.
    package static func startsSubagent(tool: String) -> Bool {
        tool == "Agent" || tool == "Task"
    }

    /// A `Bash` call the model sent to the background: it returns at once and
    /// the shell keeps running, so its result is not its outcome.
    package static func isBackgroundedShell(tool: String, input: [String: Any]) -> Bool {
        tool == "Bash" && input["run_in_background"] as? Bool == true
    }

    /// The line a started task's row carries under its call.
    ///
    /// A subagent reads as its type and counters — `general-purpose · 2 tools ·
    /// 16k tokens · last: Bash` while it runs, the same with its outcome once it
    /// has one. A background shell reads `running in background` until the CLI
    /// says it ended, then `finished` or how it failed, with the exit code the
    /// closing notice gave.
    package static func statusLine(for task: AgentActivity.TaskState) -> String {
        task.kind == .backgroundShell ? shellStatus(task) : subagentStatus(task)
    }

    private static func subagentStatus(_ task: AgentActivity.TaskState) -> String {
        var parts = [task.subagentType ?? "subagent"]
        if task.status.isFinished { parts.append(outcome(task.status)) }
        if let progress = task.progress { parts += counters(progress, withLastTool: !task.status.isFinished) }
        if parts.count == 1 { parts.append("starting") }
        return parts.joined(separator: " · ")
    }

    private static func counters(_ progress: AgentTaskProgress, withLastTool: Bool) -> [String] {
        var parts: [String] = []
        if let uses = progress.toolUses { parts.append(String(count: uses, noun: "tool")) }
        if let tokens = progress.totalTokens { parts.append("\(compactTokens(tokens)) tokens") }
        if withLastTool, let last = progress.lastToolName { parts.append("last: \(last)") }
        return parts
    }

    private static func shellStatus(_ task: AgentActivity.TaskState) -> String {
        guard task.status.isFinished else { return "running in background" }
        let word = task.status == .completed ? "finished" : outcome(task.status)
        return exitCode(in: task.summary).map { "\(word) · exit code \($0)" } ?? word
    }

    private static func outcome(_ status: AgentTaskStatus) -> String {
        switch status {
        case .running: return "running"
        case .completed: return "completed"
        case .failed: return "failed"
        case .killed: return "stopped"
        case .other(let raw): return raw
        }
    }

    /// The exit code a shell's closing notice names — `… completed (exit code
    /// 0)` — or nil when it names none.
    package static func exitCode(in summary: String?) -> Int? {
        guard let summary,
              let match = summary.firstMatch(of: /exit code (-?\d+)/) else { return nil }
        return Int(match.1)
    }

    /// `16213` as `16k`, `950` as it is, `1_200_000` as `1.2M`: a caption's
    /// worth of precision.
    package static func compactTokens(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1_000 { return "\(Int((Double(count) / 1_000).rounded()))k" }
        return "\(count)"
    }

    /// The thinking row's label. Current models send their thinking block with
    /// no text, so the row says how much was thought instead —
    /// `Thinking… (201 tokens)` — when the CLI estimated it.
    package static func thinkingLabel(text: String, estimatedTokens: Int?) -> String {
        guard isBlankThinking(text), let estimatedTokens else { return "Thinking…" }
        return "Thinking… (\(String(count: estimatedTokens, noun: "token")))"
    }

    /// Whether a thinking row has anything to unfold. An empty one does not.
    package static func isBlankThinking(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The strip above the input while background tasks run — `Background: 1
    /// running · Run the tests` — or nil when none is.
    package static func backgroundSummary(_ tasks: [AgentActivityEvent.BackgroundTask]) -> String? {
        guard !tasks.isEmpty else { return nil }
        let names = tasks.map(\.description).filter { !$0.isEmpty }
        let head = "Background: \(tasks.count) running"
        return names.isEmpty ? head : ([head] + names).joined(separator: " · ")
    }

    /// The system line a rate-limit notice earns, or nil.
    ///
    /// The CLI sends one of these as a matter of course, with `allowed`; that
    /// says nothing anyone can act on and gets no line. Anything else — a
    /// warning, a refusal — gets one, once: the same status for the same window
    /// again is the same news.
    package static func rateLimitNotice(
        previous: AgentActivityEvent.RateLimitInfo?,
        current: AgentActivityEvent.RateLimitInfo,
        resetTime: (Date) -> String = { $0.formatted(date: .omitted, time: .shortened) }
    ) -> String? {
        guard current.status != "allowed" else { return nil }
        guard previous?.status != current.status || previous?.window != current.window else { return nil }
        let window = current.window.map { " (\($0.replacingOccurrences(of: "_", with: "-")) window)" } ?? ""
        let used = current.utilization.map { " — \(Int(($0 * 100).rounded()))% used" } ?? ""
        let resets = current.resetsAt.map { ", resets \(resetTime($0))" } ?? ""
        let headline = current.status == "rejected" ? "Rate limit reached" : "Approaching the rate limit"
        return headline + window + used + resets
    }
}

/// Which tool-call rows the chat draws at the top level and which it hangs
/// under the subagent call that made them.
package enum ToolCallNesting {

    /// False for a call a subagent made, and for what it said or thought: it
    /// is drawn under its `Agent` row, not as the agent's own.
    package static func isTopLevel(_ message: Message) -> Bool {
        subagentParent(of: message) == nil
    }

    /// The `Agent`/`Task` call a subagent's call, text or thinking belongs
    /// under; nil for the agent's own, and for anything else.
    package static func subagentParent(of message: Message) -> String? {
        switch message.content {
        case .toolCall(let call): return call.parentToolUseID
        case .text, .thinking: return message.parentToolUseID
        default: return nil
        }
    }

    /// Every subagent's calls, text and thinking, in the order they came,
    /// keyed by the id of the call that started the subagent. Results are
    /// not among them: each is drawn with the call it answers.
    package static func childMessages(in messages: [Message]) -> [String: [Message]] {
        var children: [String: [Message]] = [:]
        for message in messages {
            guard let parent = subagentParent(of: message) else { continue }
            children[parent, default: []].append(message)
        }
        return children
    }

    /// Every subagent's calls, in the order they were made, keyed by the id of
    /// the call that started the subagent.
    package static func children(in messages: [Message]) -> [String: [Message.ToolCall]] {
        var children: [String: [Message.ToolCall]] = [:]
        for message in messages {
            guard case .toolCall(let call) = message.content, let parent = call.parentToolUseID else { continue }
            children[parent, default: []].append(call)
        }
        return children
    }
}
