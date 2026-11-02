import XCTest
@testable import Kiteloop

/// Tests that replay recorded CLI interactions and verify the full streaming pipeline
/// produces correct cross-agent routing behavior.
///
/// These fixtures were captured from a live session where:
/// - Alpha successfully sent a message to Gamma (allowed)
/// - Alpha attempted to message Beta (denied by permissions)
final class ReplayScenarioTests: XCTestCase {

    // MARK: - Scenario: Alpha sends to Gamma (success)

    func testReplay_AlphaSendsToGamma_ToolCallAndResponse() async throws {
        let runtime = try loadFixture("alpha_send_gamma_denied_beta")

        let agent = Agent(id: "alpha", name: "Alpha", model: "sonnet", systemPrompt: "", tools: [], denied: [], permissionMode: "default", state: .idle)
        let session = try await runtime.startSession(agent: agent, cwd: URL(filePath: "/tmp"))

        // Replay interaction 0: Alpha sends "Hi" to Gamma
        var events: [StreamEvent] = []
        for await event in runtime.send("Send Hi to Gamma", to: session) {
            events.append(event)
        }

        // Should contain a tool_use for message_agent targeting Gamma
        let toolUse = events.first { event in
            if case .toolUse(_, let name, let input, _) = event {
                return name == "mcp__kiteloop-tools__message_agent" && input.contains("Gamma")
            }
            return false
        }
        XCTAssertNotNil(toolUse, "Expected message_agent tool call targeting Gamma")

        // Should contain a tool_result with Gamma's response
        let toolResult = events.first { event in
            if case .toolResult(_, let output, _) = event {
                return output.contains("Greetings") || output.contains("Kiteloop")
            }
            return false
        }
        XCTAssertNotNil(toolResult, "Expected tool result with Gamma's response")

        // Should end with assistant text summarizing the response
        let assistantText = events.first { event in
            if case .assistantText(let text, _) = event {
                return text.contains("Gamma")
            }
            return false
        }
        XCTAssertNotNil(assistantText, "Expected assistant text mentioning Gamma")

        // Should have a .result event closing the stream
        let result = events.last { event in
            if case .result = event { return true }
            return false
        }
        XCTAssertNotNil(result, "Expected .result event")

        XCTAssertTrue(runtime.exhaustions.isEmpty, "Fixture should not run out of recorded interactions")
    }

    // MARK: - Scenario: Alpha sends to Beta (permission denied)

    func testReplay_AlphaSendsToBeta_AccessDenied() async throws {
        let runtime = try loadFixture("alpha_send_gamma_denied_beta")

        let agent = Agent(id: "alpha", name: "Alpha", model: "sonnet", systemPrompt: "", tools: [], denied: [], permissionMode: "default", state: .idle)
        let session = try await runtime.startSession(agent: agent, cwd: URL(filePath: "/tmp"))

        // Skip interaction 0 (the Gamma send)
        for await _ in runtime.send("Send Hi to Gamma", to: session) {}

        // Replay interaction 1: Alpha tries to send "Hi" to Beta
        var events: [StreamEvent] = []
        for await event in runtime.send("And now say hi to Beta", to: session) {
            events.append(event)
        }

        // Should contain a tool_use for message_agent targeting Beta
        let toolUse = events.first { event in
            if case .toolUse(_, let name, let input, _) = event {
                return name == "mcp__kiteloop-tools__message_agent" && input.contains("Beta")
            }
            return false
        }
        XCTAssertNotNil(toolUse, "Expected message_agent tool call targeting Beta")

        // Should contain a tool_result with the access denied error
        let denied = events.first { event in
            if case .toolResult(_, let output, _) = event {
                return output.contains("access denied") || output.contains("not permitted")
            }
            return false
        }
        XCTAssertNotNil(denied, "Expected access denied in tool result")

        // Should end with assistant text acknowledging the denial
        let assistantText = events.first { event in
            if case .assistantText(let text, _) = event {
                return text.contains("ward") || text.contains("block") || text.contains("denied")
            }
            return false
        }
        XCTAssertNotNil(assistantText, "Expected assistant text acknowledging denial")

        XCTAssertTrue(runtime.exhaustions.isEmpty, "Fixture should not run out of recorded interactions")
    }

    // MARK: - Scenario: Full sequence (both interactions in order)

    func testReplay_FullSequence_GammaSuccessThenBetaDenied() async throws {
        let runtime = try loadFixture("alpha_send_gamma_denied_beta")

        let agent = Agent(id: "alpha", name: "Alpha", model: "sonnet", systemPrompt: "", tools: [], denied: [], permissionMode: "default", state: .idle)
        let session = try await runtime.startSession(agent: agent, cwd: URL(filePath: "/tmp"))

        // Interaction 0: successful send to Gamma
        var gammaEvents: [StreamEvent] = []
        for await event in runtime.send("Send Hi to Gamma", to: session) {
            gammaEvents.append(event)
        }

        // Interaction 1: denied send to Beta
        var betaEvents: [StreamEvent] = []
        for await event in runtime.send("And now say hi to Beta", to: session) {
            betaEvents.append(event)
        }

        // Gamma interaction should have more events (successful round-trip)
        XCTAssertGreaterThan(gammaEvents.count, betaEvents.count,
            "Successful send should produce more events than denied send")

        // Verify both ended with .result
        let gammaResult = gammaEvents.contains { if case .result = $0 { return true }; return false }
        let betaResult = betaEvents.contains { if case .result = $0 { return true }; return false }
        XCTAssertTrue(gammaResult, "Gamma interaction should complete with .result")
        XCTAssertTrue(betaResult, "Beta interaction should complete with .result")

        XCTAssertTrue(runtime.exhaustions.isEmpty, "Fixture should not run out of recorded interactions")
    }

    // MARK: - Scenario: Gamma receives and responds

    func testReplay_GammaReceivesMessage_ProducesResponse() async throws {
        let runtime = try loadFixture("gamma_responds_to_alpha")

        let agent = Agent(id: "gamma", name: "Gamma", model: "sonnet", systemPrompt: "", tools: [], denied: [], permissionMode: "default", state: .idle)
        let session = try await runtime.startSession(agent: agent, cwd: URL(filePath: "/tmp"))

        var events: [StreamEvent] = []
        for await event in runtime.send("[Alpha]: Hi", to: session) {
            events.append(event)
        }

        // Should produce assistant text (Gamma's reply)
        let hasText = events.contains { event in
            if case .assistantText = event { return true }
            return false
        }
        XCTAssertTrue(hasText, "Gamma should produce assistant text in response")

        // Should complete with .result
        let hasResult = events.contains { if case .result = $0 { return true }; return false }
        XCTAssertTrue(hasResult, "Stream should end with .result")

        XCTAssertTrue(runtime.exhaustions.isEmpty, "Fixture should not run out of recorded interactions")
    }

    // MARK: - Timing verification

    func testReplay_InstantMode_CompletesQuickly() async throws {
        let runtime = try loadFixture("alpha_send_gamma_denied_beta")

        let agent = Agent(id: "alpha", name: "Alpha", model: "sonnet", systemPrompt: "", tools: [], denied: [], permissionMode: "default", state: .idle)
        let session = try await runtime.startSession(agent: agent, cwd: URL(filePath: "/tmp"))

        let start = Date()
        for await _ in runtime.send("Send Hi to Gamma", to: session) {}
        for await _ in runtime.send("And now say hi to Beta", to: session) {}
        let elapsed = Date().timeIntervalSince(start)

        // Original recording had ~31s of delays — instant mode should be < 1s
        XCTAssertLessThan(elapsed, 1.0,
            "Instant replay should complete in under 1s (original was ~31s)")

        XCTAssertTrue(runtime.exhaustions.isEmpty, "Fixture should not run out of recorded interactions")
    }

    // MARK: - Helpers

    private func loadFixture(_ name: String) throws -> ReplayAgentRuntime {
        let bundle = Bundle(for: type(of: self))
        return try ReplayAgentRuntime.load(resource: name, bundle: bundle, timingMode: .instant)
    }
}
