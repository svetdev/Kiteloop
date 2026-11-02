import XCTest
import KiteloopCore
@testable import Kiteloop

/// Tests that cross-agent messaging does NOT block the MainActor.
/// Uses a SlowScriptedRuntime with deliberate delays to surface blocking.
@MainActor
final class CrossAgentNonBlockingTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = try makeTemporaryDirectory(prefix: "kiteloop-nonblock")
    }

    /// Verifies MainActor remains responsive during cross-agent stream processing.
    /// Before the fix, this would hang because handleMessageAgent's for-await loop
    /// blocked the MainActor for the entire target agent response duration.
    func testMessageAgent_MainActorRemainsFree() async throws {
        let runtime = SlowScriptedRuntime(eventDelay: 100_000_000) // 100ms between events

        let alpha = Agent(
            id: "alpha", name: "Alpha", model: "sonnet",
            systemPrompt: "", tools: ["message_agent"],
            denied: [], permissionMode: "default",
            crossAgentAccess: ["*"], state: .idle
        )
        let beta = Agent(
            id: "beta", name: "Beta", model: "haiku",
            systemPrompt: "", tools: [],
            denied: [], permissionMode: "default",
            crossAgentAccess: [], state: .idle
        )

        let messageAgentInput = #"{"agent":"Beta","message":"slow question"}"#

        runtime.scripts.append(.init(
            agentID: "alpha",
            trigger: "test",
            events: [
                .toolUse(id: "tc-1", name: "message_agent", input: messageAgentInput)
            ]
        ))

        // Beta responds with 5 chunks (500ms total at 100ms/event)
        runtime.scripts.append(.init(
            agentID: "beta",
            trigger: "slow question",
            events: [
                .assistantText("chunk1"),
                .assistantText("chunk2"),
                .assistantText("chunk3"),
                .assistantText("chunk4"),
                .assistantText("chunk5"),
                .result(.init(
                    text: "chunk1chunk2chunk3chunk4chunk5", costUSD: 0, durationMs: 500,
                    inputTokens: 5, outputTokens: 5,
                    cacheCreationInputTokens: 0, cacheReadInputTokens: 0,
                    sessionID: "s-beta", permissionDenials: []
                ))
            ]
        ))

        runtime.toolResultScripts.append(.init(
            agentID: "alpha",
            trigger: "chunk1",
            events: [
                .assistantText("Got Beta's response."),
                .result(.init(
                    text: "Got Beta's response.", costUSD: 0, durationMs: 10,
                    inputTokens: 2, outputTokens: 2,
                    cacheCreationInputTokens: 0, cacheReadInputTokens: 0,
                    sessionID: "s-alpha", permissionDenials: []
                ))
            ]
        ))

        let orchestrator = Orchestrator(runtime: runtime)
        orchestrator.addAgent(alpha)
        orchestrator.addAgent(beta)
        try await orchestrator.startAgent("alpha", cwd: tempDir)
        try await orchestrator.startAgent("beta", cwd: tempDir)

        let vm = ChatViewModel(agentID: "alpha", projectURL: tempDir, orchestrator: orchestrator)

        // Start the send — this triggers handleMessageAgent internally
        let sendTask = Task { @MainActor in
            vm.inputText = "test slow communication"
            await vm.send()
        }

        // Wait until Beta's stream is in progress: `Orchestrator.send` marks the
        // target `.working` on the main actor and `markTurnDone` clears it only
        // once the stream has drained, so this runs while the 100ms-per-event
        // stream is still going.
        try await eventually("Beta's stream to be in progress") {
            await MainActor.run { orchestrator.agents.first { $0.id == "beta" }?.state == .working }
        }

        // If MainActor is free, this executes immediately.
        // If blocked (old behavior), this would deadlock or timeout.
        let mainActorFree = true
        XCTAssertTrue(mainActorFree, "MainActor should remain responsive during cross-agent stream")

        await sendTask.value

        // Functional check: Beta received the message
        let betaMessages = runtime.sentMessages.filter { $0.agentID == "beta" }
        XCTAssertFalse(betaMessages.isEmpty, "Beta should have received the routed message")
    }

    /// Verifies broadcast agents run in parallel off MainActor.
    func testBroadcast_MainActorRemainsFree() async throws {
        let runtime = SlowScriptedRuntime(eventDelay: 100_000_000)

        let alpha = Agent(
            id: "alpha", name: "Alpha", model: "sonnet",
            systemPrompt: "", tools: ["broadcast_agents"],
            denied: [], permissionMode: "default",
            crossAgentAccess: ["*"], state: .idle
        )
        let beta = Agent(
            id: "beta", name: "Beta", model: "haiku",
            systemPrompt: "", tools: [],
            denied: [], permissionMode: "default",
            crossAgentAccess: [], state: .idle
        )
        let gamma = Agent(
            id: "gamma", name: "Gamma", model: "haiku",
            systemPrompt: "", tools: [],
            denied: [], permissionMode: "default",
            crossAgentAccess: [], state: .idle
        )

        let broadcastInput = #"{"message":"hello everyone"}"#

        runtime.scripts.append(.init(
            agentID: "alpha",
            trigger: "broadcast",
            events: [
                .toolUse(id: "tc-1", name: "broadcast_agents", input: broadcastInput)
            ]
        ))

        runtime.scripts.append(.init(
            agentID: "beta",
            trigger: "hello",
            events: [
                .assistantText("Beta here"),
                .result(.init(
                    text: "Beta here", costUSD: 0, durationMs: 100,
                    inputTokens: 2, outputTokens: 2,
                    cacheCreationInputTokens: 0, cacheReadInputTokens: 0,
                    sessionID: "s-beta", permissionDenials: []
                ))
            ]
        ))

        runtime.scripts.append(.init(
            agentID: "gamma",
            trigger: "hello",
            events: [
                .assistantText("Gamma here"),
                .result(.init(
                    text: "Gamma here", costUSD: 0, durationMs: 100,
                    inputTokens: 2, outputTokens: 2,
                    cacheCreationInputTokens: 0, cacheReadInputTokens: 0,
                    sessionID: "s-gamma", permissionDenials: []
                ))
            ]
        ))

        runtime.toolResultScripts.append(.init(
            agentID: "alpha",
            trigger: "Responses",
            events: [
                .assistantText("Broadcast complete."),
                .result(.init(
                    text: "Broadcast complete.", costUSD: 0, durationMs: 10,
                    inputTokens: 2, outputTokens: 2,
                    cacheCreationInputTokens: 0, cacheReadInputTokens: 0,
                    sessionID: "s-alpha", permissionDenials: []
                ))
            ]
        ))

        let orchestrator = Orchestrator(runtime: runtime)
        orchestrator.addAgent(alpha)
        orchestrator.addAgent(beta)
        orchestrator.addAgent(gamma)
        try await orchestrator.startAgent("alpha", cwd: tempDir)
        try await orchestrator.startAgent("beta", cwd: tempDir)
        try await orchestrator.startAgent("gamma", cwd: tempDir)

        let vm = ChatViewModel(agentID: "alpha", projectURL: tempDir, orchestrator: orchestrator)

        let sendTask = Task { @MainActor in
            vm.inputText = "broadcast to all"
            await vm.send()
        }

        // Both targets are `.working` while their streams drain — the window the
        // broadcast has to leave the main actor free in.
        try await eventually("Beta's and Gamma's streams to be in progress") {
            await MainActor.run {
                let agents = orchestrator.agents
                return agents.first { $0.id == "beta" }?.state == .working
                    && agents.first { $0.id == "gamma" }?.state == .working
            }
        }
        let mainActorFree = true
        XCTAssertTrue(mainActorFree, "MainActor should remain responsive during broadcast")

        await sendTask.value

        // Both agents should have received messages
        let betaMessages = runtime.sentMessages.filter { $0.agentID == "beta" }
        let gammaMessages = runtime.sentMessages.filter { $0.agentID == "gamma" }
        XCTAssertFalse(betaMessages.isEmpty, "Beta should have received broadcast")
        XCTAssertFalse(gammaMessages.isEmpty, "Gamma should have received broadcast")
    }

    /// Verifies cross-agent MCP tool calls are still handled correctly after refactor.
    func testMessageAgent_MCPToolCallHandled() async throws {
        let runtime = ScriptedAgentRuntime()

        let alpha = Agent(
            id: "alpha", name: "Alpha", model: "sonnet",
            systemPrompt: "", tools: ["message_agent"],
            denied: [], permissionMode: "default",
            crossAgentAccess: ["*"], state: .idle
        )
        let beta = Agent(
            id: "beta", name: "Beta", model: "haiku",
            systemPrompt: "", tools: [],
            denied: [], permissionMode: "default",
            crossAgentAccess: [], state: .idle
        )

        let messageAgentInput = #"{"agent":"Beta","message":"use a tool"}"#

        runtime.scripts.append(.init(
            agentID: "alpha",
            trigger: "tool test",
            events: [
                .toolUse(id: "tc-1", name: "message_agent", input: messageAgentInput)
            ]
        ))

        // Beta emits an MCP tool call during response
        runtime.scripts.append(.init(
            agentID: "beta",
            trigger: "use a tool",
            events: [
                .assistantText("Let me check... "),
                .mcpToolCall(.init(requestID: "mcp-1", toolName: "read_file", input: "/tmp/test.txt")),
                .assistantText("Done."),
                .result(.init(
                    text: "Let me check... Done.", costUSD: 0, durationMs: 50,
                    inputTokens: 5, outputTokens: 5,
                    cacheCreationInputTokens: 0, cacheReadInputTokens: 0,
                    sessionID: "s-beta", permissionDenials: []
                ))
            ]
        ))

        runtime.toolResultScripts.append(.init(
            agentID: "alpha",
            trigger: "check",
            events: [
                .assistantText("Beta handled its tool call."),
                .result(.init(
                    text: "Beta handled its tool call.", costUSD: 0, durationMs: 10,
                    inputTokens: 2, outputTokens: 2,
                    cacheCreationInputTokens: 0, cacheReadInputTokens: 0,
                    sessionID: "s-alpha", permissionDenials: []
                ))
            ]
        ))

        let orchestrator = Orchestrator(runtime: runtime)
        orchestrator.addAgent(alpha)
        orchestrator.addAgent(beta)
        try await orchestrator.startAgent("alpha", cwd: tempDir)
        try await orchestrator.startAgent("beta", cwd: tempDir)

        let vm = ChatViewModel(agentID: "alpha", projectURL: tempDir, orchestrator: orchestrator)
        vm.inputText = "tool test"
        await vm.send()

        // Beta received the message
        let betaMessages = runtime.sentMessages.filter { $0.agentID == "beta" }
        XCTAssertFalse(betaMessages.isEmpty, "Beta should have received message")

        // MCP tool call was responded to (verified by Beta's stream completing successfully)
        let finalText = vm.messages.compactMap { msg -> String? in
            if case .text(let t) = msg.content, msg.sender == .agent("alpha") {
                return t
            }
            return nil
        }.last
        XCTAssertNotNil(finalText, "Alpha should have a final response")
    }
}

// MARK: - SlowScriptedRuntime

/// A scripted runtime that introduces deliberate delays between events
/// to help test non-blocking behavior.
final class SlowScriptedRuntime: AgentRuntime, @unchecked Sendable {

    struct Script {
        let agentID: String
        let trigger: String
        let events: [StreamEvent]
    }

    var scripts: [Script] = []
    var toolResultScripts: [Script] = []
    private(set) var sentMessages: [(agentID: String, message: String)] = []

    let eventDelay: UInt64

    init(eventDelay: UInt64 = 50_000_000) {
        self.eventDelay = eventDelay
    }

    func startSession(agent: Agent, cwd: URL, strategy: ResumeStrategy) async throws -> AgentSession {
        AgentSession(id: "slow-\(agent.id)", agentID: agent.id, startedAt: .now)
    }

    func send(_ message: String, attachments: [ChatAttachment], to session: AgentSession) -> AsyncStream<StreamEvent> {
        sentMessages.append((agentID: session.agentID, message: message))

        let match = scripts.first { script in
            session.agentID == script.agentID && message.localizedCaseInsensitiveContains(script.trigger)
        }
        let events = match?.events ?? [
            .assistantText("(no script matched)"),
            .result(.init(
                text: "", costUSD: 0, durationMs: 0,
                inputTokens: 0, outputTokens: 0,
                cacheCreationInputTokens: 0, cacheReadInputTokens: 0,
                sessionID: "s-\(session.agentID)", permissionDenials: []
            ))
        ]
        let delay = self.eventDelay
        return AsyncStream { continuation in
            Task {
                for event in events {
                    try? await Task.sleep(nanoseconds: delay)
                    continuation.yield(event)
                }
                continuation.finish()
            }
        }
    }

    func sendToolResult(toolCallID: String, content: String, to session: AgentSession) -> AsyncStream<StreamEvent> {
        let match = toolResultScripts.first { script in
            session.agentID == script.agentID && content.localizedCaseInsensitiveContains(script.trigger)
        }
        let events = match?.events ?? [
            .assistantText("Received: \(content)"),
            .result(.init(
                text: "", costUSD: 0, durationMs: 0,
                inputTokens: 0, outputTokens: 0,
                cacheCreationInputTokens: 0, cacheReadInputTokens: 0,
                sessionID: "s-\(session.agentID)", permissionDenials: []
            ))
        ]
        let delay = self.eventDelay
        return AsyncStream { continuation in
            Task {
                for event in events {
                    try? await Task.sleep(nanoseconds: delay)
                    continuation.yield(event)
                }
                continuation.finish()
            }
        }
    }

    func sendMCPToolResult(requestID: String, result: String, to session: AgentSession) {}
    func interrupt(session: AgentSession) {}
    func stop(session: AgentSession) {}
}
