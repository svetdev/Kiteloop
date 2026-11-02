import XCTest
import KiteloopCore
@testable import Kiteloop

/// Scripted runtime that returns different stream events based on which agent
/// receives a message. Allows deterministic testing of cross-agent routing
/// without hitting Bedrock.
final class ScriptedAgentRuntime: AgentRuntime, @unchecked Sendable {

    struct Script {
        let agentID: String
        let trigger: String
        let events: [StreamEvent]
    }

    var scripts: [Script] = []
    var toolResultScripts: [Script] = []
    private(set) var sentMessages: [(agentID: String, message: String)] = []

    func startSession(agent: Agent, cwd: URL, strategy: ResumeStrategy) async throws -> AgentSession {
        AgentSession(id: "scripted-\(agent.id)", agentID: agent.id, startedAt: .now)
    }

    func send(_ message: String, attachments: [ChatAttachment], to session: AgentSession) -> AsyncStream<StreamEvent> {
        sentMessages.append((agentID: session.agentID, message: message))

        let match = scripts.first { script in
            session.agentID == script.agentID && message.localizedCaseInsensitiveContains(script.trigger)
        }
        let events = match?.events ?? [
            .assistantText("(no script matched for \(session.agentID))"),
            .result(.init(
                text: "", costUSD: 0, durationMs: 0,
                inputTokens: 0, outputTokens: 0,
                cacheCreationInputTokens: 0, cacheReadInputTokens: 0,
                sessionID: "s-\(session.agentID)", permissionDenials: []
            ))
        ]

        return AsyncStream { continuation in
            Task {
                for event in events {
                    continuation.yield(event)
                    try? await Task.sleep(nanoseconds: 10_000_000)
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

        return AsyncStream { continuation in
            Task {
                for event in events {
                    continuation.yield(event)
                    try? await Task.sleep(nanoseconds: 10_000_000)
                }
                continuation.finish()
            }
        }
    }

    func sendMCPToolResult(requestID: String, result: String, to session: AgentSession) {}
    func interrupt(session: AgentSession) {}
    func stop(session: AgentSession) {}
}

// MARK: - Scenario 1: Ping-Pong

@MainActor
final class CrossAgentRoutingTests: XCTestCase {
    private var tempDir: URL!
    private var runtime: ScriptedAgentRuntime!

    override func setUpWithError() throws {
        tempDir = try makeTemporaryDirectory(prefix: "kiteloop-routing")
        runtime = ScriptedAgentRuntime()
    }

    /// Alpha asks Beta "What is 2+2?" via message_agent.
    /// Beta responds "4 — Beta". Alpha relays the answer.
    func testPingPong_AlphaMessagesBetaAndRelaysResponse() async throws {
        // -- Agent setup --
        let alpha = Agent(
            id: "alpha", name: "Alpha", model: "sonnet",
            systemPrompt: "You are Alpha.", tools: ["message_agent"],
            denied: [], permissionMode: "default",
            crossAgentAccess: ["*"], state: .idle
        )
        let beta = Agent(
            id: "beta", name: "Beta", model: "haiku",
            systemPrompt: "You are Beta.", tools: [],
            denied: [], permissionMode: "default",
            crossAgentAccess: [], state: .idle
        )

        // -- Script the mock responses --
        let messageAgentInput = #"{"agent":"Beta","message":"What is 2+2?"}"#

        // When Alpha gets the user message, it decides to call message_agent
        runtime.scripts.append(.init(
            agentID: "alpha",
            trigger: "Ask Beta",
            events: [
                .toolUse(id: "tool-call-1", name: "message_agent", input: messageAgentInput)
            ]
        ))

        // When Beta receives the routed message, respond with the answer
        runtime.scripts.append(.init(
            agentID: "beta",
            trigger: "2+2",
            events: [
                .assistantText("4 — Beta"),
                .result(.init(
                    text: "4 — Beta", costUSD: 0.0001, durationMs: 50,
                    inputTokens: 5, outputTokens: 3,
                    cacheCreationInputTokens: 0, cacheReadInputTokens: 0,
                    sessionID: "s-beta", permissionDenials: []
                ))
            ]
        ))

        // When Alpha gets Beta's response as a tool result, produce final text
        runtime.toolResultScripts.append(.init(
            agentID: "alpha",
            trigger: "4 — Beta",
            events: [
                .assistantText("Beta says the answer is 4 — Beta"),
                .result(.init(
                    text: "Beta says the answer is 4 — Beta", costUSD: 0.001, durationMs: 100,
                    inputTokens: 10, outputTokens: 8,
                    cacheCreationInputTokens: 0, cacheReadInputTokens: 0,
                    sessionID: "s-alpha", permissionDenials: []
                ))
            ]
        ))

        // -- Wire up orchestrator --
        let orchestrator = Orchestrator(runtime: runtime)
        orchestrator.addAgent(alpha)
        orchestrator.addAgent(beta)
        try await orchestrator.startAgent("alpha", cwd: tempDir)
        try await orchestrator.startAgent("beta", cwd: tempDir)

        // -- Execute --
        let vm = ChatViewModel(agentID: "alpha", projectURL: tempDir, orchestrator: orchestrator)
        vm.inputText = "Ask Beta what 2+2 is and tell me the answer."
        await vm.send()

        // -- Assertions --

        // 1. Alpha should have emitted a tool call for message_agent
        let hasToolCall = vm.messages.contains { msg in
            if case .toolCall(let call) = msg.content {
                return call.name == "message_agent"
            }
            return false
        }
        XCTAssertTrue(hasToolCall, "Expected message_agent tool call in Alpha's messages")

        // 2. The runtime should have received a message routed to Beta
        let betaMessages = runtime.sentMessages.filter { $0.agentID == "beta" }
        XCTAssertFalse(betaMessages.isEmpty, "Expected at least one message routed to Beta")
        XCTAssertTrue(
            betaMessages.first?.message.contains("2+2") == true,
            "Beta should have received a message about 2+2"
        )

        // 3. The message to Beta should be prefixed with Alpha's name
        XCTAssertTrue(
            betaMessages.first?.message.hasPrefix("[Alpha]:") == true,
            "Cross-agent message should be prefixed with sender name"
        )

        // 4. Alpha's final response should contain Beta's answer
        let finalText = vm.messages.compactMap { msg -> String? in
            if case .text(let t) = msg.content, msg.sender == .agent("alpha") {
                return t
            }
            return nil
        }.last
        XCTAssertNotNil(finalText, "Expected final text from Alpha")
        XCTAssertTrue(
            finalText?.contains("4") == true,
            "Alpha's final response should relay Beta's answer containing '4'"
        )

        // 5. A crossAgentMessageCompleted notification should have fired
        // (verified implicitly — if handleMessageAgent succeeded, the notification was posted)
    }

    /// Verifies that the message sent to Beta includes the proper [Alpha]: prefix format.
    func testPingPong_MessagePrefixFormat() async throws {
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

        let messageAgentInput = #"{"agent":"Beta","message":"hello"}"#
        runtime.scripts.append(.init(
            agentID: "alpha",
            trigger: "greet",
            events: [
                .toolUse(id: "tc-1", name: "message_agent", input: messageAgentInput)
            ]
        ))
        runtime.scripts.append(.init(
            agentID: "beta",
            trigger: "hello",
            events: [
                .assistantText("Hi there — Beta"),
                .result(.init(
                    text: "Hi there — Beta", costUSD: 0, durationMs: 10,
                    inputTokens: 2, outputTokens: 2,
                    cacheCreationInputTokens: 0, cacheReadInputTokens: 0,
                    sessionID: "s-beta", permissionDenials: []
                ))
            ]
        ))
        runtime.toolResultScripts.append(.init(
            agentID: "alpha",
            trigger: "Hi there",
            events: [
                .assistantText("Done."),
                .result(.init(
                    text: "Done.", costUSD: 0, durationMs: 10,
                    inputTokens: 2, outputTokens: 1,
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
        vm.inputText = "greet Beta for me"
        await vm.send()

        let betaMsg = runtime.sentMessages.first { $0.agentID == "beta" }
        XCTAssertEqual(betaMsg?.message, "[Alpha]: hello")
    }

    /// Validates case-insensitive agent name resolution in message_agent.
    func testPingPong_CaseInsensitiveNameResolution() async throws {
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

        // Use "beta" (lowercase) in the tool input — should still resolve
        let messageAgentInput = #"{"agent":"beta","message":"ping"}"#
        runtime.scripts.append(.init(
            agentID: "alpha",
            trigger: "test",
            events: [
                .toolUse(id: "tc-1", name: "message_agent", input: messageAgentInput)
            ]
        ))
        runtime.scripts.append(.init(
            agentID: "beta",
            trigger: "ping",
            events: [
                .assistantText("pong"),
                .result(.init(
                    text: "pong", costUSD: 0, durationMs: 10,
                    inputTokens: 1, outputTokens: 1,
                    cacheCreationInputTokens: 0, cacheReadInputTokens: 0,
                    sessionID: "s-beta", permissionDenials: []
                ))
            ]
        ))
        runtime.toolResultScripts.append(.init(
            agentID: "alpha",
            trigger: "pong",
            events: [
                .assistantText("Got pong."),
                .result(.init(
                    text: "Got pong.", costUSD: 0, durationMs: 10,
                    inputTokens: 2, outputTokens: 1,
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
        vm.inputText = "test case resolution"
        await vm.send()

        // Beta was resolved despite lowercase name in input
        let betaMessages = runtime.sentMessages.filter { $0.agentID == "beta" }
        XCTAssertFalse(betaMessages.isEmpty, "Beta should receive message despite lowercase name in tool input")
    }

    /// When Beta's stream yields no text, Alpha should get "(no response)".
    func testPingPong_EmptyResponseFromTarget() async throws {
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

        let messageAgentInput = #"{"agent":"Beta","message":"silence"}"#
        runtime.scripts.append(.init(
            agentID: "alpha",
            trigger: "silent",
            events: [
                .toolUse(id: "tc-1", name: "message_agent", input: messageAgentInput)
            ]
        ))
        // Beta emits result with empty text and no assistantText chunks
        runtime.scripts.append(.init(
            agentID: "beta",
            trigger: "silence",
            events: [
                .result(.init(
                    text: "", costUSD: 0, durationMs: 10,
                    inputTokens: 1, outputTokens: 0,
                    cacheCreationInputTokens: 0, cacheReadInputTokens: 0,
                    sessionID: "s-beta", permissionDenials: []
                ))
            ]
        ))
        // Alpha gets "(no response)" as tool result
        runtime.toolResultScripts.append(.init(
            agentID: "alpha",
            trigger: "(no response)",
            events: [
                .assistantText("Beta didn't respond."),
                .result(.init(
                    text: "Beta didn't respond.", costUSD: 0, durationMs: 10,
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
        vm.inputText = "ask the silent agent"
        await vm.send()

        let finalText = vm.messages.compactMap { msg -> String? in
            if case .text(let t) = msg.content, msg.sender == .agent("alpha") {
                return t
            }
            return nil
        }.last
        XCTAssertTrue(
            finalText?.contains("didn't respond") == true || finalText?.contains("no response") == true,
            "Alpha should handle empty response from Beta gracefully"
        )
    }

    /// `all` is the same wildcard as `*` for message_agent, not the name of an
    /// agent called "all".
    func testAllWildcardLetsCallerMessageAnotherAgent() async throws {
        let betaMessages = try await messagesToBeta(whenAlphaHolds: ["all"])
        XCTAssertEqual(betaMessages, ["[Alpha]: hello"])
    }

    /// A list that names only other agents still refuses the one it leaves out.
    func testListNamingOnlyOthersRefusesUnnamedTarget() async throws {
        let betaMessages = try await messagesToBeta(whenAlphaHolds: ["Gamma"])
        XCTAssertTrue(betaMessages.isEmpty, "Beta is not on Alpha's list")
    }

    private func messagesToBeta(whenAlphaHolds access: [String]) async throws -> [String] {
        let alpha = Agent(
            id: "alpha", name: "Alpha", model: "sonnet",
            systemPrompt: "", tools: ["message_agent"],
            denied: [], permissionMode: "default",
            crossAgentAccess: access, state: .idle
        )
        let beta = Agent(
            id: "beta", name: "Beta", model: "haiku",
            systemPrompt: "", tools: [],
            denied: [], permissionMode: "default",
            crossAgentAccess: [], state: .idle
        )
        runtime.scripts.append(.init(
            agentID: "alpha",
            trigger: "greet",
            events: [.toolUse(id: "tc-1", name: "message_agent", input: #"{"agent":"Beta","message":"hello"}"#)]
        ))

        let orchestrator = Orchestrator(runtime: runtime)
        orchestrator.addAgent(alpha)
        orchestrator.addAgent(beta)
        try await orchestrator.startAgent("alpha", cwd: tempDir)
        try await orchestrator.startAgent("beta", cwd: tempDir)

        let vm = ChatViewModel(agentID: "alpha", projectURL: tempDir, orchestrator: orchestrator)
        vm.inputText = "greet Beta for me"
        await vm.send()

        return runtime.sentMessages.filter { $0.agentID == "beta" }.map(\.message)
    }
}
