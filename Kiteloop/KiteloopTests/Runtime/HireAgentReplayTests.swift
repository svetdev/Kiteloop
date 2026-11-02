import XCTest
@testable import Kiteloop

/// Tests that replay the hire_agent / fire_agent tool flow and verify
/// the streaming pipeline produces correct MCP tool call sequences.
///
/// Fixture recorded from a session where the Archmage:
/// - Hired a Coder agent via hire_agent (success)
/// - Fired the Coder agent via fire_agent (success)
final class HireAgentReplayTests: XCTestCase {

    // MARK: - Scenario: Archmage hires a Coder

    func testReplay_ArchmageHiresCoder_ToolCallAndResponse() async throws {
        let runtime = try loadFixture("archmage_hires_coder")

        let agent = Agent(id: "archmage", name: "Archmage", model: "sonnet", systemPrompt: "", tools: [], denied: [], permissionMode: "default", state: .idle)
        let session = try await runtime.startSession(agent: agent, cwd: URL(filePath: "/tmp"))

        var events: [StreamEvent] = []
        for await event in runtime.send("Hire a coder", to: session) {
            events.append(event)
        }

        // Should contain a tool_use for hire_agent
        let toolUse = events.first { event in
            if case .toolUse(_, let name, let input, _) = event {
                return name == "mcp__kiteloop-tools__hire_agent" && input.contains("coder")
            }
            return false
        }
        XCTAssertNotNil(toolUse, "Expected hire_agent tool call with role 'coder'")

        // Should contain a mcpToolCall event
        let mcpCall = events.first { event in
            if case .mcpToolCall(let payload) = event {
                return payload.toolName == "hire_agent"
            }
            return false
        }
        XCTAssertNotNil(mcpCall, "Expected mcpToolCall event for hire_agent")

        // Should contain a tool_result with success message
        let toolResult = events.first { event in
            if case .toolResult(_, let output, _) = event {
                return output.contains("Hired") && output.contains("Coder")
            }
            return false
        }
        XCTAssertNotNil(toolResult, "Expected tool result confirming hire")

        // Should end with assistant text acknowledging the hire
        let assistantText = events.first { event in
            if case .assistantText(let text, _) = event {
                return text.contains("Coder") && text.contains("Kiteloop")
            }
            return false
        }
        XCTAssertNotNil(assistantText, "Expected assistant text mentioning the hired Coder")

        // Should have a .result event closing the stream
        let result = events.last { event in
            if case .result = event { return true }
            return false
        }
        XCTAssertNotNil(result, "Expected .result event")

        XCTAssertTrue(runtime.exhaustions.isEmpty, "Fixture should not run out of recorded interactions")
    }

    // MARK: - Scenario: Archmage fires the Coder

    func testReplay_ArchmageFiresCoder_ToolCallAndResponse() async throws {
        let runtime = try loadFixture("archmage_hires_coder")

        let agent = Agent(id: "archmage", name: "Archmage", model: "sonnet", systemPrompt: "", tools: [], denied: [], permissionMode: "default", state: .idle)
        let session = try await runtime.startSession(agent: agent, cwd: URL(filePath: "/tmp"))

        // Skip interaction 0 (the hire)
        for await _ in runtime.send("Hire a coder", to: session) {}

        // Replay interaction 1: fire the Coder
        var events: [StreamEvent] = []
        for await event in runtime.send("Fire the Coder", to: session) {
            events.append(event)
        }

        // Should contain a tool_use for fire_agent
        let toolUse = events.first { event in
            if case .toolUse(_, let name, let input, _) = event {
                return name == "mcp__kiteloop-tools__fire_agent" && input.contains("Coder")
            }
            return false
        }
        XCTAssertNotNil(toolUse, "Expected fire_agent tool call targeting Coder")

        // Should contain a tool_result confirming dismissal
        let toolResult = events.first { event in
            if case .toolResult(_, let output, _) = event {
                return output.contains("Dismissed") && output.contains("Coder")
            }
            return false
        }
        XCTAssertNotNil(toolResult, "Expected tool result confirming dismissal")

        // Should end with assistant text acknowledging
        let assistantText = events.first { event in
            if case .assistantText(let text, _) = event {
                return text.contains("Coder") && text.contains("released")
            }
            return false
        }
        XCTAssertNotNil(assistantText, "Expected assistant text acknowledging dismissal")

        XCTAssertTrue(runtime.exhaustions.isEmpty, "Fixture should not run out of recorded interactions")
    }

    // MARK: - Scenario: Full hire-then-fire sequence

    func testReplay_FullHireFireSequence() async throws {
        let runtime = try loadFixture("archmage_hires_coder")

        let agent = Agent(id: "archmage", name: "Archmage", model: "sonnet", systemPrompt: "", tools: [], denied: [], permissionMode: "default", state: .idle)
        let session = try await runtime.startSession(agent: agent, cwd: URL(filePath: "/tmp"))

        // Interaction 0: hire
        var hireEvents: [StreamEvent] = []
        for await event in runtime.send("Hire a coder", to: session) {
            hireEvents.append(event)
        }

        // Interaction 1: fire
        var fireEvents: [StreamEvent] = []
        for await event in runtime.send("Fire the Coder", to: session) {
            fireEvents.append(event)
        }

        // Both should complete with .result
        let hireResult = hireEvents.contains { if case .result = $0 { return true }; return false }
        let fireResult = fireEvents.contains { if case .result = $0 { return true }; return false }
        XCTAssertTrue(hireResult, "Hire interaction should complete with .result")
        XCTAssertTrue(fireResult, "Fire interaction should complete with .result")

        // Hire should produce more events (has thinking + mcpToolCall + toolUse + toolResult + text + result)
        XCTAssertGreaterThanOrEqual(hireEvents.count, 6, "Hire should have at least 6 events")
        XCTAssertGreaterThanOrEqual(fireEvents.count, 5, "Fire should have at least 5 events")

        XCTAssertTrue(runtime.exhaustions.isEmpty, "Fixture should not run out of recorded interactions")
    }

    // MARK: - Timing verification

    func testReplay_InstantMode_CompletesQuickly() async throws {
        let runtime = try loadFixture("archmage_hires_coder")

        let agent = Agent(id: "archmage", name: "Archmage", model: "sonnet", systemPrompt: "", tools: [], denied: [], permissionMode: "default", state: .idle)
        let session = try await runtime.startSession(agent: agent, cwd: URL(filePath: "/tmp"))

        let start = Date()
        for await _ in runtime.send("Hire a coder", to: session) {}
        for await _ in runtime.send("Fire the Coder", to: session) {}
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 1.0,
            "Instant replay should complete in under 1s (original ~9s)")

        XCTAssertTrue(runtime.exhaustions.isEmpty, "Fixture should not run out of recorded interactions")
    }

    // MARK: - Helpers

    private func loadFixture(_ name: String) throws -> ReplayAgentRuntime {
        let bundle = Bundle(for: type(of: self))
        return try ReplayAgentRuntime.load(resource: name, bundle: bundle, timingMode: .instant)
    }
}
