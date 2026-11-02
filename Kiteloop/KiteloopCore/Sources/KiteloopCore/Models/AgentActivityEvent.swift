import Foundation

/// What the `claude` CLI says, in its stream, about work running beside the
/// conversation: a subagent or a background shell it started, how far it has
/// got, how it ended, which background tasks are still up, how much the model
/// has thought so far, and where the account stands against its rate limit.
///
/// Each arrives as a line of its own — a `system` line with one of the
/// subtypes in `subtypes`, or the top-level `rate_limit_event` — and none of
/// it is conversation content, so the app's `StreamEvent` carries these lines
/// as `.system(subtype:payload:)` and this reads them. A subtype this does not
/// know is not an error: `parse` answers nil and the line is ignored, because
/// the CLI adds subtypes and an older Kiteloop must not break on a new one.
package enum AgentActivityEvent: Equatable, Sendable {
    case taskStarted(TaskStarted)
    case taskProgress(TaskProgress)
    case taskUpdated(taskID: String, status: AgentTaskStatus?)
    case taskNotification(TaskNotification)
    /// The whole current list, not a change to it: `[]` means none is running.
    case backgroundTasksChanged([BackgroundTask])
    /// The model's thinking so far this turn, as the CLI estimates it. Sent
    /// before the thinking block itself, which current models leave empty.
    case thinkingTokens(estimated: Int)
    case rateLimit(RateLimitInfo)

    /// The top-level line type the rate-limit notice arrives as. `StreamEvent`
    /// hands it on as a `system` line of this subtype.
    package static let rateLimitType = "rate_limit_event"

    /// `task_started`: a subagent or a background shell began.
    package struct TaskStarted: Equatable, Sendable {
        package let taskID: String
        /// The `Agent` or `Bash` call that started it.
        package let toolUseID: String?
        package let kind: AgentTaskKind
        package let description: String
        package let subagentType: String?
        package let isBackgrounded: Bool
    }

    /// `task_progress`: a running subagent's counters so far.
    package struct TaskProgress: Equatable, Sendable {
        package let taskID: String
        package let toolUseID: String?
        package let progress: AgentTaskProgress
    }

    /// `task_notification`: how a task ended, told to the model.
    package struct TaskNotification: Equatable, Sendable {
        package let taskID: String
        package let toolUseID: String?
        package let status: AgentTaskStatus
        package let outputFile: String?
        package let summary: String?
        /// The final counters, when the notice carries them.
        package let usage: AgentTaskProgress?
    }

    /// One row of `background_tasks_changed`.
    package struct BackgroundTask: Equatable, Sendable {
        package let taskID: String
        package let kind: AgentTaskKind
        package let description: String

        package init(taskID: String, kind: AgentTaskKind, description: String) {
            self.taskID = taskID
            self.kind = kind
            self.description = description
        }
    }

    /// `rate_limit_event`'s `rate_limit_info`.
    package struct RateLimitInfo: Equatable, Sendable {
        /// `allowed` while under the limit; anything else says something.
        package let status: String
        /// The window the status is about — `five_hour`, `seven_day`.
        package let window: String?
        package let resetsAt: Date?
        /// That window's share used, 0…1, when the event reports it.
        package let utilization: Double?

        package init(status: String, window: String?, resetsAt: Date?, utilization: Double?) {
            self.status = status
            self.window = window
            self.resetsAt = resetsAt
            self.utilization = utilization
        }
    }

    // MARK: - Parsing

    private typealias Reader = @Sendable ([String: Any]) -> AgentActivityEvent?

    /// A table rather than a switch, so a new subtype is a row, not a branch.
    private static let readers: [String: Reader] = [
        "task_started": readTaskStarted,
        "task_progress": readTaskProgress,
        "task_updated": readTaskUpdated,
        "task_notification": readTaskNotification,
        "background_tasks_changed": readBackgroundTasks,
        "thinking_tokens": readThinkingTokens,
        rateLimitType: readRateLimit,
    ]

    /// The subtypes this reads — everything else a `system` line can say is
    /// someone else's.
    package static var subtypes: Set<String> { Set(readers.keys) }

    /// The event a `system` line of `subtype` carries, or nil for a subtype
    /// this does not read or a line missing what the subtype needs.
    package static func parse(subtype: String, payload: [String: Any]) -> AgentActivityEvent? {
        readers[subtype]?(payload)
    }

    /// The same, from a whole decoded stream line: a `system` line by its
    /// subtype, a `rate_limit_event` by its type.
    package static func parse(json: [String: Any]) -> AgentActivityEvent? {
        let type = json["type"] as? String
        let subtype = type == "system" ? json["subtype"] as? String : type
        return subtype.flatMap { parse(subtype: $0, payload: json) }
    }

    private static func readTaskStarted(_ json: [String: Any]) -> AgentActivityEvent? {
        guard let taskID = json["task_id"] as? String else { return nil }
        return .taskStarted(TaskStarted(
            taskID: taskID,
            toolUseID: json["tool_use_id"] as? String,
            kind: AgentTaskKind(taskType: json["task_type"] as? String),
            description: json["description"] as? String ?? "",
            subagentType: json["subagent_type"] as? String,
            isBackgrounded: json["is_backgrounded"] as? Bool ?? false
        ))
    }

    private static func readTaskProgress(_ json: [String: Any]) -> AgentActivityEvent? {
        guard let taskID = json["task_id"] as? String else { return nil }
        let progress = AgentTaskProgress(usage: json["usage"] as? [String: Any] ?? [:],
                                         lastToolName: json["last_tool_name"] as? String)
        return .taskProgress(TaskProgress(taskID: taskID, toolUseID: json["tool_use_id"] as? String,
                                          progress: progress))
    }

    private static func readTaskUpdated(_ json: [String: Any]) -> AgentActivityEvent? {
        guard let taskID = json["task_id"] as? String else { return nil }
        let patch = json["patch"] as? [String: Any] ?? [:]
        return .taskUpdated(taskID: taskID, status: (patch["status"] as? String).map(AgentTaskStatus.init))
    }

    private static func readTaskNotification(_ json: [String: Any]) -> AgentActivityEvent? {
        guard let taskID = json["task_id"] as? String,
              let status = json["status"] as? String else { return nil }
        return .taskNotification(TaskNotification(
            taskID: taskID,
            toolUseID: json["tool_use_id"] as? String,
            status: AgentTaskStatus(status),
            outputFile: json["output_file"] as? String,
            summary: json["summary"] as? String,
            usage: (json["usage"] as? [String: Any]).map { AgentTaskProgress(usage: $0, lastToolName: nil) }
        ))
    }

    private static func readBackgroundTasks(_ json: [String: Any]) -> AgentActivityEvent? {
        guard let rows = json["tasks"] as? [[String: Any]] else { return nil }
        return .backgroundTasksChanged(rows.compactMap { row in
            guard let taskID = row["task_id"] as? String else { return nil }
            return BackgroundTask(taskID: taskID, kind: AgentTaskKind(taskType: row["task_type"] as? String),
                                  description: row["description"] as? String ?? "")
        })
    }

    private static func readThinkingTokens(_ json: [String: Any]) -> AgentActivityEvent? {
        (json["estimated_tokens"] as? Int).map { .thinkingTokens(estimated: $0) }
    }

    private static func readRateLimit(_ json: [String: Any]) -> AgentActivityEvent? {
        guard let info = json["rate_limit_info"] as? [String: Any],
              let status = info["status"] as? String else { return nil }
        let window = info["rateLimitType"] as? String
        let windows = info["unifiedWindows"] as? [String: Any] ?? [:]
        let current = window.flatMap { windows[$0] as? [String: Any] } ?? [:]
        return .rateLimit(RateLimitInfo(
            status: status,
            window: window,
            resetsAt: (info["resetsAt"] as? Double).map { Date(timeIntervalSince1970: $0) },
            utilization: current["utilization"] as? Double
        ))
    }
}

/// What kind of work a task is, from the CLI's `task_type`.
package enum AgentTaskKind: Equatable, Sendable {
    /// `local_agent` — an `Agent`/`Task` call's subagent.
    case subagent
    /// `local_bash` — a shell the model sent to the background.
    case backgroundShell
    case other(String)

    package init(taskType: String?) {
        switch taskType {
        case "local_agent": self = .subagent
        case "local_bash": self = .backgroundShell
        default: self = .other(taskType ?? "")
        }
    }
}

/// Where a task stands, as the CLI spells it. Running until something says
/// otherwise; a status this does not know is kept as written.
package enum AgentTaskStatus: Equatable, Sendable {
    case running
    case completed
    case failed
    case killed
    case other(String)

    package init(_ raw: String) {
        switch raw {
        case "running", "pending": self = .running
        case "completed": self = .completed
        case "failed": self = .failed
        case "killed", "stopped": self = .killed
        default: self = .other(raw)
        }
    }

    package var isFinished: Bool { self != .running }
}

/// A running subagent's counters, from a `task_progress` or the closing
/// notification's `usage`.
package struct AgentTaskProgress: Equatable, Sendable {
    package var totalTokens: Int?
    package var toolUses: Int?
    package var durationMs: Int?
    package var lastToolName: String?

    package init(totalTokens: Int? = nil, toolUses: Int? = nil, durationMs: Int? = nil, lastToolName: String? = nil) {
        self.totalTokens = totalTokens
        self.toolUses = toolUses
        self.durationMs = durationMs
        self.lastToolName = lastToolName
    }

    init(usage: [String: Any], lastToolName: String?) {
        self.init(totalTokens: usage["total_tokens"] as? Int,
                  toolUses: usage["tool_uses"] as? Int,
                  durationMs: usage["duration_ms"] as? Int,
                  lastToolName: lastToolName)
    }

    /// `newer` over this, field by field: a notice that carries no last tool
    /// does not erase the one the last progress named.
    package func updated(with newer: AgentTaskProgress) -> AgentTaskProgress {
        AgentTaskProgress(totalTokens: newer.totalTokens ?? totalTokens,
                          toolUses: newer.toolUses ?? toolUses,
                          durationMs: newer.durationMs ?? durationMs,
                          lastToolName: newer.lastToolName ?? lastToolName)
    }
}

/// Which call a stream line belongs to.
package enum StreamLineage {
    /// The `Agent`/`Task` call whose subagent produced this line, or nil for
    /// the main agent's own. The CLI writes `null` for the main agent, which
    /// decodes as `NSNull`, not as a missing key.
    package static func parentToolUseID(in json: [String: Any]) -> String? {
        guard let id = json["parent_tool_use_id"] as? String, !id.isEmpty else { return nil }
        return id
    }
}
