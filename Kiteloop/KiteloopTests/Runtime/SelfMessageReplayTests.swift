import XCTest
@testable import Kiteloop

/// Tests that replay the self-message (self-scrying) flow: an agent sends
/// message_agent targeting itself and receives the echo back.
///
/// Fixture models the scenario: Archmage sends "Echo test: can you hear
/// yourself?" to itself via message_agent.
final class SelfMessageReplayTests: XCTestCase {

    // MARK: - Scenario: Self-message round-trip

    func testReplay_SelfMessage_TargetsOwnName() async throws {
        let runtime = try loadFixture("archmage_messages_self")

        let agent = Agent(id: "archmage", name: "Archmage", model: "sonnet", systemPrompt: "", tools: [], denied: [], permissionMode: "default", state: .idle)
        let session = try await runtime.startSession(agent: agent, cwd: URL(filePath: "/tmp"))

        var events: [StreamEvent] = []
        for await event in runtime.send("Send a message to yourself using message_agent", to: session) {
            events.append(event)
        }

        // message_agent should target the agent's own name
        let selfToolUse = events.first { event in
            if case .toolUse(_, let name, let input, _) = event {
                return name == "mcp__kiteloop-tools__message_agent" && input.contains("Archmage")
            }
            return false
        }
        XCTAssertNotNil(selfToolUse, "Expected message_agent to target Archmage (self)")

        XCTAssertTrue(runtime.exhaustions.isEmpty, "Fixture should not run out of recorded interactions")
    }

    func testReplay_SelfMessage_ReceivesEcho() async throws {
        let runtime = try loadFixture("archmage_messages_self")

        let agent = Agent(id: "archmage", name: "Archmage", model: "sonnet", systemPrompt: "", tools: [], denied: [], permissionMode: "default", state: .idle)
        let session = try await runtime.startSession(agent: agent, cwd: URL(filePath: "/tmp"))

        var events: [StreamEvent] = []
        for await event in runtime.send("Send a message to yourself using message_agent", to: session) {
            events.append(event)
        }

        // Tool result should contain the echo response
        let echoResult = events.first { event in
            if case .toolResult(_, let output, _) = event {
                return output.contains("[Archmage]") && output.contains("self-routing path is operational")
            }
            return false
        }
        XCTAssertNotNil(echoResult, "Expected echo response from self-message")

        XCTAssertTrue(runtime.exhaustions.isEmpty, "Fixture should not run out of recorded interactions")
    }

    func testReplay_SelfMessage_AssistantConfirmsRoute() async throws {
        let runtime = try loadFixture("archmage_messages_self")

        let agent = Agent(id: "archmage", name: "Archmage", model: "sonnet", systemPrompt: "", tools: [], denied: [], permissionMode: "default", state: .idle)
        let session = try await runtime.startSession(agent: agent, cwd: URL(filePath: "/tmp"))

        var events: [StreamEvent] = []
        for await event in runtime.send("Send a message to yourself using message_agent", to: session) {
            events.append(event)
        }

        // Assistant text should confirm the self-routing works
        let confirmation = events.first { event in
            if case .assistantText(let text, _) = event {
                return text.contains("self-scrying") && text.contains("echo received")
            }
            return false
        }
        XCTAssertNotNil(confirmation, "Expected assistant to confirm self-scrying channel works")

        XCTAssertTrue(runtime.exhaustions.isEmpty, "Fixture should not run out of recorded interactions")
    }

    func testReplay_SelfMessage_SingleToolCall() async throws {
        let runtime = try loadFixture("archmage_messages_self")

        let agent = Agent(id: "archmage", name: "Archmage", model: "sonnet", systemPrompt: "", tools: [], denied: [], permissionMode: "default", state: .idle)
        let session = try await runtime.startSession(agent: agent, cwd: URL(filePath: "/tmp"))

        var events: [StreamEvent] = []
        for await event in runtime.send("Send a message to yourself using message_agent", to: session) {
            events.append(event)
        }

        // Should have exactly 1 message_agent call (self only)
        let messageToolUses = events.filter { event in
            if case .toolUse(_, let name, _, _) = event {
                return name == "mcp__kiteloop-tools__message_agent"
            }
            return false
        }
        XCTAssertEqual(messageToolUses.count, 1, "Expected exactly 1 message_agent tool call for self-message")

        XCTAssertTrue(runtime.exhaustions.isEmpty, "Fixture should not run out of recorded interactions")
    }

    func testReplay_SelfMessage_InstantMode() async throws {
        let runtime = try loadFixture("archmage_messages_self")

        let agent = Agent(id: "archmage", name: "Archmage", model: "sonnet", systemPrompt: "", tools: [], denied: [], permissionMode: "default", state: .idle)
        let session = try await runtime.startSession(agent: agent, cwd: URL(filePath: "/tmp"))

        let start = Date()
        for await _ in runtime.send("Send a message to yourself using message_agent", to: session) {}
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 1.0,
            "Instant replay should complete in under 1s (original ~5.8s)")

        XCTAssertTrue(runtime.exhaustions.isEmpty, "Fixture should not run out of recorded interactions")
    }

    // MARK: - Helpers

    private func loadFixture(_ name: String) throws -> ReplayAgentRuntime {
        let bundle = Bundle(for: type(of: self))
        return try ReplayAgentRuntime.load(resource: name, bundle: bundle, timingMode: .instant)
    }
}
