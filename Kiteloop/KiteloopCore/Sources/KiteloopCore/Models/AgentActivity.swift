import Foundation

/// What one agent's session has running beside its conversation, folded from
/// the `AgentActivityEvent`s its stream sends: every subagent and background
/// shell it started, the background tasks still up, the current turn's
/// thinking estimate and the last rate-limit notice.
///
/// A value, so it is folded with `apply` and asserted without a session. It
/// belongs to the session it was folded from: a new chat or a restarted
/// process starts from `AgentActivity()`.
package struct AgentActivity: Equatable, Sendable {

    /// One subagent or background shell, keyed by the CLI's `task_id` and
    /// linked to the tool call that started it.
    package struct TaskState: Equatable, Sendable {
        package let taskID: String
        package var toolUseID: String?
        package var kind: AgentTaskKind
        package var description: String
        package var subagentType: String?
        package var isBackgrounded: Bool
        package var status: AgentTaskStatus = .running
        package var progress: AgentTaskProgress?
        package var outputFile: String?
        /// The closing notification's own sentence — for a shell, the one that
        /// carries its exit code.
        package var summary: String?

        package init(taskID: String, toolUseID: String? = nil, kind: AgentTaskKind = .other(""),
                     description: String = "", subagentType: String? = nil, isBackgrounded: Bool = false) {
            self.taskID = taskID
            self.toolUseID = toolUseID
            self.kind = kind
            self.description = description
            self.subagentType = subagentType
            self.isBackgrounded = isBackgrounded
        }
    }

    /// A finished task as a chat saves it: what its row reads, in the CLI's
    /// own spellings, so it decodes into the same `TaskState` the live row
    /// draws from.
    package struct SavedTask: Codable, Equatable, Sendable {
        package var taskType: String
        package var status: String
        package var description: String
        package var subagentType: String?
        package var toolUses: Int?
        package var totalTokens: Int?
        package var durationMs: Int?
        package var summary: String?

        package init(_ task: TaskState) {
            taskType = task.kind.taskType
            status = task.status.raw
            description = task.description
            subagentType = task.subagentType
            toolUses = task.progress?.toolUses
            totalTokens = task.progress?.totalTokens
            durationMs = task.progress?.durationMs
            summary = task.summary
        }

        /// The state the row draws, for the call `toolUseID`.
        package func taskState(toolUseID: String) -> TaskState {
            var task = TaskState(taskID: "saved-\(toolUseID)", toolUseID: toolUseID,
                                 kind: AgentTaskKind(taskType: taskType), description: description,
                                 subagentType: subagentType)
            task.status = AgentTaskStatus(status)
            task.progress = AgentTaskProgress(totalTokens: totalTokens, toolUses: toolUses, durationMs: durationMs)
            task.summary = summary
            return task
        }
    }

    /// Every finished task that names the call it belongs to, keyed by that
    /// call's id — what a chat saves onto its tool calls.
    package var finishedTasksByToolUseID: [String: TaskState] {
        var finished: [String: TaskState] = [:]
        for task in tasks.values where task.status.isFinished {
            if let toolUseID = task.toolUseID { finished[toolUseID] = task }
        }
        return finished
    }

    package private(set) var tasks: [String: TaskState] = [:]
    private var taskIDsByToolUseID: [String: String] = [:]
    /// The background tasks the CLI last said are running, in its order.
    package private(set) var backgroundTasks: [AgentActivityEvent.BackgroundTask] = []
    /// The model's thinking so far, as the CLI last estimated it. Nil until an
    /// estimate arrives, and again once `takeThinkingEstimate` has claimed it.
    package private(set) var thinkingTokens: Int?
    package private(set) var rateLimit: AgentActivityEvent.RateLimitInfo?

    package init() {}

    /// The task the tool call `toolUseID` started, if the stream has said so.
    package func task(forToolUseID toolUseID: String) -> TaskState? {
        taskIDsByToolUseID[toolUseID].flatMap { tasks[$0] }
    }

    /// The estimate, handed to the thinking block it belongs to and cleared,
    /// so the next block does not inherit it.
    package mutating func takeThinkingEstimate() -> Int? {
        defer { thinkingTokens = nil }
        return thinkingTokens
    }

    package mutating func apply(_ event: AgentActivityEvent) {
        switch event {
        case .taskStarted(let started): start(started)
        case .taskProgress(let update): progress(update)
        case .taskUpdated(let taskID, let status): updateTask(taskID) { task in status.map { task.status = $0 } }
        case .taskNotification(let notice): finish(notice)
        case .backgroundTasksChanged(let list): backgroundTasks = list
        case .thinkingTokens(let estimated): thinkingTokens = estimated
        case .rateLimit(let info): rateLimit = info
        }
    }

    private mutating func start(_ started: AgentActivityEvent.TaskStarted) {
        link(started.taskID, to: started.toolUseID)
        updateTask(started.taskID) { task in
            task.kind = started.kind
            task.description = started.description
            task.subagentType = started.subagentType
            task.isBackgrounded = started.isBackgrounded
        }
    }

    private mutating func progress(_ update: AgentActivityEvent.TaskProgress) {
        link(update.taskID, to: update.toolUseID)
        updateTask(update.taskID) { task in
            task.progress = task.progress?.updated(with: update.progress) ?? update.progress
        }
    }

    private mutating func finish(_ notice: AgentActivityEvent.TaskNotification) {
        link(notice.taskID, to: notice.toolUseID)
        updateTask(notice.taskID) { task in
            task.status = notice.status
            task.outputFile = notice.outputFile ?? task.outputFile
            task.summary = notice.summary ?? task.summary
            if let usage = notice.usage {
                task.progress = task.progress?.updated(with: usage) ?? usage
            }
        }
    }

    private mutating func link(_ taskID: String, to toolUseID: String?) {
        guard let toolUseID else { return }
        taskIDsByToolUseID[toolUseID] = taskID
        updateTask(taskID) { $0.toolUseID = toolUseID }
    }

    /// Edits the task, creating it first when an event about it arrived before
    /// its `task_started` — the CLI lists a background shell before it says
    /// the shell started.
    private mutating func updateTask(_ taskID: String, _ edit: (inout TaskState) -> Void) {
        var task = tasks[taskID] ?? TaskState(taskID: taskID)
        edit(&task)
        tasks[taskID] = task
    }
}
