import Foundation

/// A worker's turn can end with the Agent tool's async-launch acknowledgement
/// as the last thing said — "Async agent launched successfully." — while the
/// subagent it started is still working. That acknowledgement is not a
/// finished thought: the subagent's report arrives later, on a turn of its
/// own, and only once every launch a turn made has been accounted for is a
/// hand-off honest about what the worker actually said.
///
/// `ChatViewModel` is the only caller. A real report never names the launch
/// it is closing out — no tool-call id, no CLI-assigned agent id — so the
/// only thing worth checking at a turn's end is whether *that* turn itself
/// made a launch nobody has answered for yet; a turn that doesn't is treated
/// as the report, whatever it says.
enum PendingAgentLaunch {
    /// The exact text the CLI's Agent/Task tool answers with the instant an
    /// async launch is accepted, before the subagent has done anything.
    static let launchPrefix = "Async agent launched successfully."

    /// Tool names the CLI uses for the same async-launch tool — `Task` is the
    /// alias `ToolCallLabel` already documents alongside `Agent`.
    static let toolNames: Set<String> = ["Agent", "Task"]

    /// True when a tool result is the launch acknowledgement itself, not the
    /// subagent's eventual answer — `toolName` is the matching `.toolUse`'s
    /// name, already resolved by the caller before the pairing is lost.
    static func isLaunchAcknowledgement(toolName: String?, output: String) -> Bool {
        guard let toolName, toolNames.contains(toolName) else { return false }
        return output.hasPrefix(launchPrefix)
    }
}
