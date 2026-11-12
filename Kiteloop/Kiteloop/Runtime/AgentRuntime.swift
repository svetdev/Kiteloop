import Foundation
import KiteloopCore

enum RuntimeKind: String, Codable, Sendable, CaseIterable {
    case claude
    case copilot
    case ollama
}

enum ResumeStrategy: Sendable {
    case fresh
    case resume(sessionID: String)
    case fork(sessionID: String)
    case compact(sessionID: String)
}

/// How a session about to be started will be driven — everything a runtime may
/// need at spawn time that isn't the agent, the directory or the resume
/// strategy.
struct SessionOptions: Sendable, Equatable {
    /// True when no human is at the other end: an autopilot worker or reviewer,
    /// or a one-shot headless call. `ClaudeCodeCLIRuntime` reads it to decide
    /// whether the spawned CLI keeps its own memory — see
    /// `ClaudeCodeCLIRuntime.sessionEnvironment(_:unattended:)`.
    var unattended: Bool = false
    /// True for a session whose mode promises to ask
    /// (`PermissionPrompt.asksBeforeListedTools`) and that a person attends:
    /// it is spawned without the agent's built-in tools approved ahead of
    /// time. Fixed at spawn — the flag cannot be taken back from a process.
    var asksBeforeListedTools: Bool = false
}

protocol AgentRuntime: Sendable {
    func startSession(agent: Agent, cwd: URL, strategy: ResumeStrategy) async throws -> AgentSession
    /// The same, for a caller that knows how the session will be driven.
    ///
    /// Defaulted below to the options-less spelling, so a runtime that spawns
    /// no process — the mock, the replay runtimes, Ollama, the Copilot bridge —
    /// needs no implementation of its own. `ClaudeCodeCLIRuntime` overrides it.
    func startSession(agent: Agent, cwd: URL, strategy: ResumeStrategy, options: SessionOptions) async throws -> AgentSession
    func send(_ message: String, attachments: [ChatAttachment], to session: AgentSession) -> AsyncStream<StreamEvent>
    func sendToolResult(toolCallID: String, content: String, to session: AgentSession) -> AsyncStream<StreamEvent>
    func sendMCPToolResult(requestID: String, result: String, to session: AgentSession)
    func interrupt(session: AgentSession)
    func stop(session: AgentSession)
    /// The turns `session` starts on its own, each as a stream of its own from
    /// its opening line through its `result` — a turn no `send` asked for, as
    /// the CLI starts when a background shell or subagent it launched
    /// finishes. The outer stream ends with the session.
    ///
    /// Defaulted below to a stream that ends at once: a runtime that only
    /// answers what it is sent never starts a turn by itself.
    func unpromptedTurns(of session: AgentSession) -> AsyncStream<AsyncStream<StreamEvent>>
    /// What `session` stops to ask — a call waiting on leave to run, the
    /// model's own question, a plan — and each question it takes back. The
    /// session waits on every one without limit; the stream ends with the
    /// session. One listener at a time: a later call takes over.
    ///
    /// Defaulted below to a stream that ends at once: a runtime that never
    /// asks has nothing to say.
    func permissionPrompts(of session: AgentSession) -> AsyncStream<PermissionPrompt.Line>
    /// Writes one line of the host's side of the control channel to `session`
    /// — an answer to a prompt, a change of mode, a task to stop
    /// (`PermissionPrompt`). Defaulted below to nothing.
    func sendControl(_ line: String, to session: AgentSession)
}

extension AgentRuntime {
    func startSession(agent: Agent, cwd: URL, strategy: ResumeStrategy, options: SessionOptions) async throws -> AgentSession {
        try await startSession(agent: agent, cwd: cwd, strategy: strategy)
    }

    func unpromptedTurns(of session: AgentSession) -> AsyncStream<AsyncStream<StreamEvent>> {
        AsyncStream { $0.finish() }
    }

    func permissionPrompts(of session: AgentSession) -> AsyncStream<PermissionPrompt.Line> {
        AsyncStream { $0.finish() }
    }

    func sendControl(_ line: String, to session: AgentSession) {}

    func startSession(agent: Agent, cwd: URL) async throws -> AgentSession {
        try await startSession(agent: agent, cwd: cwd, strategy: .fresh)
    }

    func startSession(agent: Agent, cwd: URL, resumeSessionID: String?, forkSession: Bool) async throws -> AgentSession {
        let strategy: ResumeStrategy
        if let sessionID = resumeSessionID {
            strategy = forkSession ? .fork(sessionID: sessionID) : .resume(sessionID: sessionID)
        } else {
            strategy = .fresh
        }
        return try await startSession(agent: agent, cwd: cwd, strategy: strategy)
    }

    func startSession(agent: Agent, cwd: URL, resumeSessionID: String?) async throws -> AgentSession {
        try await startSession(agent: agent, cwd: cwd, resumeSessionID: resumeSessionID, forkSession: false)
    }

    func send(_ message: String, to session: AgentSession) -> AsyncStream<StreamEvent> {
        send(message, attachments: [], to: session)
    }
}

struct AgentSession: Identifiable, Sendable {
    let id: String
    let agentID: String
    let startedAt: Date
}

enum RuntimeError: LocalizedError {
    case sessionNotFound
    case processSpawnFailed(String)
    case processNotRunning

    var errorDescription: String? {
        switch self {
        case .sessionNotFound: return "Agent session not found"
        case .processSpawnFailed(let msg): return "Failed to spawn process: \(msg)"
        case .processNotRunning: return "Process is not running"
        }
    }
}

@MainActor
class RuntimeRegistry {
    private var runtimes: [RuntimeKind: any AgentRuntime] = [:]

    func register(_ kind: RuntimeKind, runtime: any AgentRuntime) {
        runtimes[kind] = runtime
    }

    func runtime(for agent: Agent) -> any AgentRuntime {
        let kind = agent.resolvedRuntimeKind
        return runtimes[kind] ?? runtimes[.claude]!
    }

    func runtime(for kind: RuntimeKind) -> (any AgentRuntime)? {
        runtimes[kind]
    }

    var defaultRuntime: any AgentRuntime {
        runtimes[.claude]!
    }

    var hasRuntime: Bool {
        !runtimes.isEmpty
    }
}
