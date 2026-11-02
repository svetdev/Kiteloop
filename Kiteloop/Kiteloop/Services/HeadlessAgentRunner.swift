import Foundation
import KiteloopCore

/// Runs a single headless prompt through the app's existing `AgentRuntime`
/// (Claude Code CLI in a project directory) and returns the assistant's text.
/// No persistent agent, no chat session — used by features that need one
/// structured model reply (backlog AI edits, task scoping).
enum HeadlessAgentRunner {

    /// The reply and what it cost. Callers that meter a budget need the cost;
    /// callers that only parse the answer use `run` and never see it.
    struct Reply: Sendable, Equatable {
        let text: String
        /// From the run's `result` event. Zero when the runtime reported none —
        /// an unknown cost is charged as nothing rather than guessed at.
        let costUSD: Double
    }

    /// The runtime reported an error and the stream ended without a reply — a
    /// `claude` that could not be provisioned, a bridge that is not running.
    /// Its description is the runtime's own reason, so a caller that shows
    /// `localizedDescription` says why rather than "empty reply".
    struct RuntimeFailure: LocalizedError, Equatable {
        let message: String
        var errorDescription: String? { message }
    }

    @MainActor
    static func run(
        prompt: String,
        cwd: URL,
        systemPrompt: String,
        agentName: String = "Kiteloop Assistant",
        /// The caller's model, when the call is standing in for a configured
        /// agent. Nil keeps the global default.
        model: String? = nil,
        /// Read-only source access, scoped to one project. Nil — every caller
        /// but the Planner's source reads — keeps the tool-less shape below.
        access: RepoRead.Grant? = nil,
        runtimeFactory: () -> any AgentRuntime,
        globalConfigStore: GlobalConfigStore
    ) async throws -> String {
        try await runDetailed(prompt: prompt, cwd: cwd, systemPrompt: systemPrompt,
                              agentName: agentName, model: model, access: access,
                              runtimeFactory: runtimeFactory,
                              globalConfigStore: globalConfigStore).text
    }

    /// The same one-shot call, with what it cost. Split out rather than folded
    /// into `run` so every existing caller keeps the string it asked for.
    /// - Parameter access: read-only source access for one named project, or nil
    ///   for the tool-less call every other caller makes. A grant **is** the
    ///   scope: the session is rooted at `grant.root` rather than at `cwd`, so a
    ///   caller cannot hand out a read of one project rooted in another — and the
    ///   agent carries `RepoRead`'s three read verbs with everything else denied
    ///   by name, rather than the base tool set an empty `tools` falls back to.
    @MainActor
    static func runDetailed(
        prompt: String,
        cwd: URL,
        systemPrompt: String,
        agentName: String = "Kiteloop Assistant",
        model: String? = nil,
        access: RepoRead.Grant? = nil,
        runtimeFactory: () -> any AgentRuntime,
        globalConfigStore: GlobalConfigStore
    ) async throws -> Reply {
        let runtime = runtimeFactory()
        let agent = Agent(
            name: agentName,
            model: model ?? globalConfigStore.config.defaultModel ?? ModelCatalog.defaultModelID,
            systemPrompt: systemPrompt,
            tools: access == nil ? [] : RepoRead.allowedTools,
            denied: access == nil ? [] : RepoRead.deniedTools,
            permissionMode: "plan"
        )
        // Unattended by construction: nobody is chatting with this agent, it
        // exists for one reply and is stopped below. Nothing it might write to a
        // self-maintained memory would ever pass a human, so it keeps none —
        // see `ClaudeCodeCLIRuntime.sessionEnvironment(_:unattended:)`.
        let session = try await runtime.startSession(agent: agent, cwd: access?.root ?? cwd,
                                                     strategy: .fresh,
                                                     options: SessionOptions(unattended: true))
        defer { runtime.stop(session: session) }

        return try await reply(from: runtime.send(prompt, to: session))
    }

    /// The reply a finished stream carried, or the runtime's own reason when it
    /// reported an error and carried nothing else.
    private static func reply(from stream: AsyncStream<StreamEvent>) async throws -> Reply {
        var text = ""
        var costUSD = 0.0
        var sawResult = false
        var failure: String?
        for await event in stream {
            switch event {
            // A subagent's prose is not the reply.
            case .assistantText(let chunk, parentToolUseID: nil):
                text += chunk
            case .result(let payload):
                if !payload.text.isEmpty { text = payload.text }
                costUSD = payload.costUSD
                sawResult = true
            case .system(subtype: "error", let payload):
                failure = payload["message"] as? String
            default:
                break
            }
        }
        // A partial answer is never thrown away: text or a result wins over an
        // error event that also came through.
        if let failure, text.isEmpty, !sawResult { throw RuntimeFailure(message: failure) }
        return Reply(text: text, costUSD: costUSD)
    }
}
