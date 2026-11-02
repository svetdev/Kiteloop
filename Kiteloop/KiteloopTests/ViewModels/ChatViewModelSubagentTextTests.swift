import XCTest
import KiteloopCore
@testable import Kiteloop

/// A subagent's forwarded prose (`--forward-subagent-text`) carries the id of
/// the call that started it, and none of the chat's answer collectors —
/// `message_agent`'s, `broadcast_agents`' — takes it in as the agent's answer.
@MainActor
final class ChatViewModelSubagentTextTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = try makeTemporaryDirectory(prefix: "kiteloop-subagent-text")
    }

    private static let chatter = "Subagent: listed the files."

    private static func reply(_ answer: String, session: String) -> [StreamEvent] {
        [
            .assistantText(chatter, parentToolUseID: "toolu_agent"),
            .thinking("", parentToolUseID: "toolu_agent"),
            .assistantText(answer),
            .result(.init(text: "", costUSD: 0, durationMs: 1, inputTokens: 1, outputTokens: 1,
                          cacheCreationInputTokens: 0, cacheReadInputTokens: 0,
                          sessionID: session, permissionDenials: [])),
        ]
    }

    private static func texts(of vm: ChatViewModel) -> [String] {
        vm.messages.compactMap { if case .text(let text) = $0.content { return text } else { return nil } }
    }

    private static func agent(_ id: String, tools: [String] = [], access: [String] = []) -> Agent {
        Agent(id: id, name: id.capitalized, model: "sonnet", systemPrompt: "", tools: tools,
              denied: [], permissionMode: "default", crossAgentAccess: access, state: .idle)
    }

    func testMessageAgentsReplyLeavesOutTheTargetsSubagentText() async throws {
        let runtime = ScriptedAgentRuntime()
        runtime.scripts.append(.init(agentID: "alpha", trigger: "ask beta", events: [
            .toolUse(id: "tc-1", name: "message_agent", input: #"{"agent":"Beta","message":"what is here"}"#),
        ]))
        runtime.scripts.append(.init(agentID: "beta", trigger: "what is here",
                                     events: Self.reply("Beta's answer", session: "s-beta")))
        try await assertAlphaHearsOnly("Beta's answer", askingWith: "ask beta", runtime: runtime,
                                       tools: ["message_agent"])
    }

    func testABroadcastsRepliesLeaveOutTheTargetsSubagentText() async throws {
        let runtime = ScriptedAgentRuntime()
        runtime.scripts.append(.init(agentID: "alpha", trigger: "tell everyone", events: [
            .toolUse(id: "tc-1", name: "broadcast_agents", input: #"{"message":"what is here"}"#),
        ]))
        runtime.scripts.append(.init(agentID: "beta", trigger: "what is here",
                                     events: Self.reply("Beta's answer", session: "s-beta")))
        try await assertAlphaHearsOnly("Beta's answer", askingWith: "tell everyone", runtime: runtime,
                                       tools: ["broadcast_agents"])
    }

    /// Alpha asks, Beta answers with its subagent's chatter ahead of its own
    /// words, and what comes back to Alpha — echoed by the scripted runtime as
    /// `Received: …` — carries Beta's words alone.
    private func assertAlphaHearsOnly(_ answer: String, askingWith prompt: String,
                                      runtime: ScriptedAgentRuntime, tools: [String]) async throws {
        let orchestrator = Orchestrator(runtime: runtime)
        orchestrator.addAgent(Self.agent("alpha", tools: tools, access: ["*"]))
        orchestrator.addAgent(Self.agent("beta"))
        try await orchestrator.startAgent("alpha", cwd: tempDir)
        try await orchestrator.startAgent("beta", cwd: tempDir)
        let vm = ChatViewModel(agentID: "alpha", projectURL: tempDir, orchestrator: orchestrator)

        vm.inputText = prompt
        await vm.send()

        let received = Self.texts(of: vm).filter { $0.hasPrefix("Received:") }
        XCTAssertEqual(received.count, 1, "\(Self.texts(of: vm))")
        XCTAssertTrue(received.first?.contains(answer) ?? false, "\(received)")
        XCTAssertFalse(received.first?.contains(Self.chatter) ?? true, "\(received)")
    }
}
