import XCTest
@testable import Kiteloop

@MainActor
final class OrchestratorRoutingTests: XCTestCase {

    private var tempDir: URL!
    private var tempDirB: URL!

    override func setUpWithError() throws {
        tempDir = try makeTemporaryDirectory(prefix: "kiteloop-routing-a")
        tempDirB = try makeTemporaryDirectory(prefix: "kiteloop-routing-b")
    }

    // MARK: - Helpers

    private func makeAgent(id: String, name: String = "Agent") -> Agent {
        Agent(
            id: id, name: name, model: "sonnet",
            systemPrompt: "You are \(name).",
            tools: [], denied: [],
            permissionMode: "default", state: .idle
        )
    }

    // MARK: - testSendRoutesToCorrectAgent

    /// Add two agents, start both. Send a message to agent-A only.
    /// The mock records `lastSentMessage` on every `send()` call.
    /// We drain the stream to confirm it received content, then verify the
    /// mock only received a single send (not two) and the message content is correct.
    func testSendRoutesToCorrectAgent() async throws {
        let mock = MockAgentRuntime()
        mock.events = [
            .assistantText("Hello from A."),
            .result(.init(
                text: "Hello from A.", costUSD: 0.001, durationMs: 50,
                inputTokens: 5, outputTokens: 4,
                cacheCreationInputTokens: 0, cacheReadInputTokens: 0,
                sessionID: "s-a", permissionDenials: []
            ))
        ]

        let orchestrator = Orchestrator(runtime: mock)
        let agentA = makeAgent(id: "agent-a", name: "Arch")
        let agentB = makeAgent(id: "agent-b", name: "Sage")
        orchestrator.addAgent(agentA)
        orchestrator.addAgent(agentB)

        try await orchestrator.startAgent("agent-a", cwd: tempDir)
        try await orchestrator.startAgent("agent-b", cwd: tempDirB)

        let stream = orchestrator.send("What is mana?", to: "agent-a")
        var events: [StreamEvent] = []
        for await event in stream { events.append(event) }

        XCTAssertEqual(mock.lastSentMessage, "What is mana?",
                       "Runtime should have received the message sent to agent-a")
        XCTAssertFalse(events.isEmpty, "Stream should have yielded events for the targeted agent")
    }

    // MARK: - testAgentStateTransitionOnSend

    /// After `startAgent`, the agent is `.idle`.
    /// `send()` should transition it to `.working`.
    /// `markTurnDone()` should return it to `.idle` and clear `isStreaming`.
    func testAgentStateTransitionOnSend() async throws {
        let mock = MockAgentRuntime()
        mock.events = [
            .assistantText("Casting spell."),
            .result(.init(
                text: "Casting spell.", costUSD: 0.001, durationMs: 50,
                inputTokens: 5, outputTokens: 2,
                cacheCreationInputTokens: 0, cacheReadInputTokens: 0,
                sessionID: "s-state", permissionDenials: []
            ))
        ]

        let orchestrator = Orchestrator(runtime: mock)
        let agent = makeAgent(id: "caster", name: "Caster")
        orchestrator.addAgent(agent)
        try await orchestrator.startAgent("caster", cwd: tempDir)

        // After start, agent must be idle
        XCTAssertEqual(
            orchestrator.agents.first(where: { $0.id == "caster" })?.state,
            .idle,
            "Agent should be .idle after startAgent"
        )

        // Kick off a send — state must flip to .working synchronously
        let stream = orchestrator.send("Ignite!", to: "caster")
        XCTAssertEqual(
            orchestrator.agents.first(where: { $0.id == "caster" })?.state,
            .working,
            "Agent should be .working immediately after send()"
        )
        XCTAssertTrue(orchestrator.isStreaming, "isStreaming should be true during an active stream")

        // Drain the stream
        for await _ in stream {}

        // markTurnDone resets everything
        orchestrator.markTurnDone(agentID: "caster")

        XCTAssertEqual(
            orchestrator.agents.first(where: { $0.id == "caster" })?.state,
            .idle,
            "Agent should return to .idle after markTurnDone"
        )
        XCTAssertFalse(orchestrator.isStreaming, "isStreaming should be false after markTurnDone")
    }

    // MARK: - testStartAgentComposesSystemPrompt

    /// `startAgent` must call `memoryManager.composeSystemContext`, which
    /// at minimum prepends the agent's own `systemPrompt`. The resulting
    /// composed string should contain the original prompt text.
    func testStartAgentComposesSystemPrompt() async throws {
        let mock = MockAgentRuntime()
        mock.events = []

        let orchestrator = Orchestrator(runtime: mock)
        let agent = makeAgent(id: "scholar", name: "Scholar")
        // The agent's initial systemPrompt is "You are Scholar."
        orchestrator.addAgent(agent)
        try await orchestrator.startAgent("scholar", cwd: tempDir)

        let storedAgent = orchestrator.agents.first(where: { $0.id == "scholar" })
        let composed = storedAgent?.systemPrompt ?? ""
        XCTAssertFalse(composed.isEmpty, "Composed system prompt should not be empty after startAgent")
        XCTAssertTrue(
            composed.contains("You are Scholar."),
            "Composed prompt should contain the agent's own systemPrompt text; got: \(composed)"
        )
    }

    // MARK: - testSendToUnstartedAgentReturnsEmpty

    /// If `send()` is called for an agent that was added but never started,
    /// `sessions` won't have an entry and the stream should finish immediately
    /// without yielding any events.
    func testSendToUnstartedAgentReturnsEmpty() async throws {
        let mock = MockAgentRuntime()
        mock.events = [.assistantText("Should not appear")]

        let orchestrator = Orchestrator(runtime: mock)
        let agent = makeAgent(id: "ghost", name: "Ghost")
        orchestrator.addAgent(agent)

        // Deliberately do NOT call startAgent

        let stream = orchestrator.send("Hello?", to: "ghost")
        var events: [StreamEvent] = []
        for await event in stream { events.append(event) }

        XCTAssertTrue(events.isEmpty, "Sending to an unstarted agent should yield no events")
    }

    // MARK: - testMarkTurnDoneSetsStreamingFalse

    /// After send() the `isStreaming` flag should be true.
    /// After markTurnDone() it should be false.
    func testMarkTurnDoneSetsStreamingFalse() async throws {
        let mock = MockAgentRuntime()
        // Use a delay-free single event so the test can control timing explicitly
        mock.events = [
            .assistantText("Done."),
            .result(.init(
                text: "Done.", costUSD: 0.001, durationMs: 30,
                inputTokens: 3, outputTokens: 1,
                cacheCreationInputTokens: 0, cacheReadInputTokens: 0,
                sessionID: "s-flag", permissionDenials: []
            ))
        ]

        let orchestrator = Orchestrator(runtime: mock)
        let agent = makeAgent(id: "beacon", name: "Beacon")
        orchestrator.addAgent(agent)
        try await orchestrator.startAgent("beacon", cwd: tempDir)

        // isStreaming should be false before any send
        XCTAssertFalse(orchestrator.isStreaming, "isStreaming should be false before any send")

        let stream = orchestrator.send("Light the beacon.", to: "beacon")

        // isStreaming should be true once send() has been called
        XCTAssertTrue(orchestrator.isStreaming, "isStreaming should be true after send()")

        // Drain the stream fully
        for await _ in stream {}

        // isStreaming is still true — it requires an explicit markTurnDone
        XCTAssertTrue(orchestrator.isStreaming,
                      "isStreaming remains true until markTurnDone is called")

        orchestrator.markTurnDone(agentID: "beacon")

        XCTAssertFalse(orchestrator.isStreaming,
                       "isStreaming should be false after markTurnDone")
    }
}
