import XCTest
@testable import Kiteloop

/// Tests that replay a multi-agent delegation flow: Lead delegates research
/// to Researcher, receives findings, then delegates implementation to Coder.
///
/// Fixture models the scenario: "I need a debounce utility in Swift. Ask
/// Researcher about the best approach, then ask Coder to write it based
/// on the research."
final class DelegationReplayTests: XCTestCase {

    // MARK: - Scenario: Lead delegates to Researcher then Coder

    func testReplay_LeadDelegates_TwoMessageAgentCalls() async throws {
        let runtime = try loadFixture("lead_delegates_research_then_code")

        let agent = Agent(id: "lead", name: "Lead", model: "sonnet", systemPrompt: "", tools: [], denied: [], permissionMode: "default", state: .idle)
        let session = try await runtime.startSession(agent: agent, cwd: URL(filePath: "/tmp"))

        var events: [StreamEvent] = []
        for await event in runtime.send("I need a debounce utility in Swift. Ask Researcher about the best approach, then ask Coder to write it based on the research.", to: session) {
            events.append(event)
        }

        // Should contain two message_agent tool calls
        let messageToolUses = events.filter { event in
            if case .toolUse(_, let name, _, _) = event {
                return name == "mcp__kiteloop-tools__message_agent"
            }
            return false
        }
        XCTAssertEqual(messageToolUses.count, 2, "Expected exactly 2 message_agent tool calls")

        XCTAssertTrue(runtime.exhaustions.isEmpty, "Fixture should not run out of recorded interactions")
    }

    func testReplay_FirstDelegation_TargetsResearcher() async throws {
        let runtime = try loadFixture("lead_delegates_research_then_code")

        let agent = Agent(id: "lead", name: "Lead", model: "sonnet", systemPrompt: "", tools: [], denied: [], permissionMode: "default", state: .idle)
        let session = try await runtime.startSession(agent: agent, cwd: URL(filePath: "/tmp"))

        var events: [StreamEvent] = []
        for await event in runtime.send("I need a debounce utility in Swift. Ask Researcher about the best approach, then ask Coder to write it based on the research.", to: session) {
            events.append(event)
        }

        // First message_agent should target Researcher
        let firstToolUse = events.first { event in
            if case .toolUse(_, let name, let input, _) = event {
                return name == "mcp__kiteloop-tools__message_agent" && input.contains("Researcher")
            }
            return false
        }
        XCTAssertNotNil(firstToolUse, "Expected first message_agent to target Researcher")

        // Researcher's response should mention debounce approaches
        let researcherResult = events.first { event in
            if case .toolResult(_, let output, _) = event {
                return output.contains("[Researcher]") && output.contains("GCD")
            }
            return false
        }
        XCTAssertNotNil(researcherResult, "Expected Researcher response with debounce approaches")

        XCTAssertTrue(runtime.exhaustions.isEmpty, "Fixture should not run out of recorded interactions")
    }

    func testReplay_SecondDelegation_TargetsCoder() async throws {
        let runtime = try loadFixture("lead_delegates_research_then_code")

        let agent = Agent(id: "lead", name: "Lead", model: "sonnet", systemPrompt: "", tools: [], denied: [], permissionMode: "default", state: .idle)
        let session = try await runtime.startSession(agent: agent, cwd: URL(filePath: "/tmp"))

        var events: [StreamEvent] = []
        for await event in runtime.send("I need a debounce utility in Swift. Ask Researcher about the best approach, then ask Coder to write it based on the research.", to: session) {
            events.append(event)
        }

        // Second message_agent should target Coder
        let coderToolUse = events.first { event in
            if case .toolUse(_, let name, let input, _) = event {
                return name == "mcp__kiteloop-tools__message_agent" && input.contains("Coder")
            }
            return false
        }
        XCTAssertNotNil(coderToolUse, "Expected second message_agent to target Coder")

        // Coder's response should contain implementation
        let coderResult = events.first { event in
            if case .toolResult(_, let output, _) = event {
                return output.contains("[Coder]") && output.contains("Debouncer")
            }
            return false
        }
        XCTAssertNotNil(coderResult, "Expected Coder response with Debouncer implementation")

        XCTAssertTrue(runtime.exhaustions.isEmpty, "Fixture should not run out of recorded interactions")
    }

    func testReplay_McpToolCalls_MatchToolUses() async throws {
        let runtime = try loadFixture("lead_delegates_research_then_code")

        let agent = Agent(id: "lead", name: "Lead", model: "sonnet", systemPrompt: "", tools: [], denied: [], permissionMode: "default", state: .idle)
        let session = try await runtime.startSession(agent: agent, cwd: URL(filePath: "/tmp"))

        var events: [StreamEvent] = []
        for await event in runtime.send("I need a debounce utility in Swift. Ask Researcher about the best approach, then ask Coder to write it based on the research.", to: session) {
            events.append(event)
        }

        // Should have 2 mcpToolCall events for message_agent
        let mcpCalls = events.filter { event in
            if case .mcpToolCall(let payload) = event {
                return payload.toolName == "message_agent"
            }
            return false
        }
        XCTAssertEqual(mcpCalls.count, 2, "Expected 2 mcpToolCall events for message_agent")

        XCTAssertTrue(runtime.exhaustions.isEmpty, "Fixture should not run out of recorded interactions")
    }

    func testReplay_FinalResponse_SummarizesWork() async throws {
        let runtime = try loadFixture("lead_delegates_research_then_code")

        let agent = Agent(id: "lead", name: "Lead", model: "sonnet", systemPrompt: "", tools: [], denied: [], permissionMode: "default", state: .idle)
        let session = try await runtime.startSession(agent: agent, cwd: URL(filePath: "/tmp"))

        var events: [StreamEvent] = []
        for await event in runtime.send("I need a debounce utility in Swift. Ask Researcher about the best approach, then ask Coder to write it based on the research.", to: session) {
            events.append(event)
        }

        // Final assistant text should summarize both delegations
        let summary = events.first { event in
            if case .assistantText(let text, _) = event {
                return text.contains("Researcher") && text.contains("Coder")
            }
            return false
        }
        XCTAssertNotNil(summary, "Expected final summary mentioning both Researcher and Coder")

        XCTAssertTrue(runtime.exhaustions.isEmpty, "Fixture should not run out of recorded interactions")
    }

    func testReplay_InstantMode_CompletesQuickly() async throws {
        let runtime = try loadFixture("lead_delegates_research_then_code")

        let agent = Agent(id: "lead", name: "Lead", model: "sonnet", systemPrompt: "", tools: [], denied: [], permissionMode: "default", state: .idle)
        let session = try await runtime.startSession(agent: agent, cwd: URL(filePath: "/tmp"))

        let start = Date()
        for await _ in runtime.send("I need a debounce utility in Swift. Ask Researcher about the best approach, then ask Coder to write it based on the research.", to: session) {}
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 1.0,
            "Instant replay should complete in under 1s (original ~18s)")

        XCTAssertTrue(runtime.exhaustions.isEmpty, "Fixture should not run out of recorded interactions")
    }

    // MARK: - Helpers

    private func loadFixture(_ name: String) throws -> ReplayAgentRuntime {
        let bundle = Bundle(for: type(of: self))
        return try ReplayAgentRuntime.load(resource: name, bundle: bundle, timingMode: .instant)
    }
}
