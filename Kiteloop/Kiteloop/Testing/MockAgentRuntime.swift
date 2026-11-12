import Foundation
import KiteloopCore

final class MockAgentRuntime: AgentRuntime, @unchecked Sendable {
    var events: [StreamEvent] = []
    var toolResultEvents: [StreamEvent] = []
    /// Distinct event streams for successive `send()` calls, consumed front to
    /// back — for a test where `send()` must answer differently each time it's
    /// called (e.g. a background agent's report arriving on a later turn),
    /// unlike `events`, which every `send()` call replays whole. Falls back to
    /// `events` once drained, so a test can seed a few distinct turns and let
    /// the rest behave as before.
    var sendEventsQueue: [[StreamEvent]] = []
    var startDelay: UInt64 = 0
    var lastSentMessage: String?
    var lastSentAttachments: [ChatAttachment] = []
    /// Every `send()` in call order, for a test that follows several turns.
    var sentMessages: [(message: String, attachments: [ChatAttachment])] = []
    /// Results handed back to Kiteloop-native MCP tool calls, in call order — the
    /// only place a test can see what a tool actually reported to the agent.
    var mcpToolResults: [String] = []
    /// Every `sendToolResult` in call order — the only place a test can see
    /// whether an answer actually reached the paused turn, and which call it
    /// was answering.
    var toolResultsSent: [(toolCallID: String, content: String)] = []
    /// How the last session was asked for — the only place a test can see the
    /// terms a spawn would have used.
    var lastSessionOptions: SessionOptions?
    /// The agent and resume strategy of the last spawn — what its permission
    /// and `--resume` arguments are built from.
    var lastStartedAgent: Agent?
    var lastStrategy: ResumeStrategy?
    /// Thrown by every `startSession` while set — a restart that cannot bring
    /// the agent back.
    var startSessionError: Error?

    func startSession(agent: Agent, cwd: URL, strategy: ResumeStrategy) async throws -> AgentSession {
        try await startSession(agent: agent, cwd: cwd, strategy: strategy, options: SessionOptions())
    }

    func startSession(agent: Agent, cwd: URL, strategy: ResumeStrategy, options: SessionOptions) async throws -> AgentSession {
        if let startSessionError { throw startSessionError }
        lastSessionOptions = options
        lastStartedAgent = agent
        lastStrategy = strategy
        return AgentSession(id: "mock-session", agentID: agent.id, startedAt: .now)
    }

    func send(_ message: String, attachments: [ChatAttachment], to session: AgentSession) -> AsyncStream<StreamEvent> {
        lastSentMessage = message
        lastSentAttachments = attachments
        sentMessages.append((message, attachments))
        let events = sendEventsQueue.isEmpty ? self.events : sendEventsQueue.removeFirst()
        let delay = self.startDelay
        return AsyncStream { continuation in
            Task {
                if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
                for event in events {
                    continuation.yield(event)
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                continuation.finish()
            }
        }
    }

    func sendToolResult(toolCallID: String, content: String, to session: AgentSession) -> AsyncStream<StreamEvent> {
        toolResultsSent.append((toolCallID, content))
        let events = self.toolResultEvents.isEmpty ? self.events : self.toolResultEvents
        return AsyncStream { continuation in
            Task {
                for event in events {
                    continuation.yield(event)
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                continuation.finish()
            }
        }
    }

    func sendMCPToolResult(requestID: String, result: String, to session: AgentSession) {
        mcpToolResults.append(result)
    }
    /// How many interrupts reached the runtime.
    var interruptCount = 0
    func interrupt(session: AgentSession) { interruptCount += 1 }
    func stop(session: AgentSession) {}

    /// Every `unpromptedTurns(of:)` subscription, oldest first. Kept, not
    /// replaced, so a test can start a turn on a session the chat has since
    /// left behind.
    private(set) var unpromptedTurnListeners: [AsyncStream<AsyncStream<StreamEvent>>.Continuation] = []

    func unpromptedTurns(of session: AgentSession) -> AsyncStream<AsyncStream<StreamEvent>> {
        let (turns, continuation) = AsyncStream<AsyncStream<StreamEvent>>.makeStream(bufferingPolicy: .unbounded)
        unpromptedTurnListeners.append(continuation)
        return turns
    }

    /// Every `permissionPrompts(of:)` subscription, oldest first.
    private(set) var promptListeners: [AsyncStream<PermissionPrompt.Line>.Continuation] = []
    /// Every control line written to a session, in order — the answers a
    /// prompt was given, a change of mode, a task stopped.
    var controlLines: [String] = []

    func permissionPrompts(of session: AgentSession) -> AsyncStream<PermissionPrompt.Line> {
        let (prompts, continuation) = AsyncStream<PermissionPrompt.Line>.makeStream(bufferingPolicy: .unbounded)
        promptListeners.append(continuation)
        return prompts
    }

    func sendControl(_ line: String, to session: AgentSession) { controlLines.append(line) }

    /// The session asks, or takes a question back, on the newest subscription.
    func prompt(_ line: PermissionPrompt.Line) {
        promptListeners.last?.yield(line)
    }

    /// Starts a turn nobody sent — what the CLI does when background work it
    /// launched finishes — on the `listener`th subscription, the newest by
    /// default, replaying `events` at the pace a `send` does.
    func startUnpromptedTurn(_ events: [StreamEvent], onListener listener: Int? = nil) {
        let (turn, continuation) = AsyncStream<StreamEvent>.makeStream(bufferingPolicy: .unbounded)
        let index = listener ?? unpromptedTurnListeners.count - 1
        unpromptedTurnListeners[index].yield(turn)
        Task {
            for event in events {
                continuation.yield(event)
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            continuation.finish()
        }
    }
}
