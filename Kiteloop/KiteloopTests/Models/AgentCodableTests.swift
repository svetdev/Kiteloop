// Kiteloop/KiteloopTests/Models/AgentCodableTests.swift
import XCTest
@testable import Kiteloop

/// `Agent` is the live, in-memory agent the orchestrator hands to a runtime — every field
/// on it feeds a CLI flag, a permission decision or a routing rule. Its `encode(to:)` is
/// synthesized but its `init(from:)` is hand-written and deliberately *forgiving*: only
/// `name` is required and everything else falls back to a default, because agent JSON is
/// hand-edited and arrives from templates, packages and the control API. That asymmetry is
/// exactly where a round-trip can silently lose a field, so these tests pin both directions —
/// what survives an encode/decode cycle, and which defaults a sparse or `null`-filled
/// payload lands on.
final class AgentCodableTests: XCTestCase {

    // MARK: - Helpers

    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private func roundTrip(_ agent: Agent) throws -> Agent {
        try JSONDecoder().decode(Agent.self, from: encoder().encode(agent))
    }

    private func decode(_ json: String) throws -> Agent {
        try JSONDecoder().decode(Agent.self, from: Data(json.utf8))
    }

    private func keys(of agent: Agent) throws -> Set<String> {
        let object = try JSONSerialization.jsonObject(with: encoder().encode(agent))
        return Set(try XCTUnwrap(object as? [String: Any]).keys)
    }

    /// Every field set to a non-default value, so a dropped key shows up as a mismatch
    /// rather than as a coincidence with the decoder's fallback.
    private func fullAgent(state: Agent.AgentState = .working) -> Agent {
        Agent(
            id: "agent-full",
            name: "Coder",
            model: "opus",
            systemPrompt: "You are a senior developer.",
            tools: ["Read", "Edit", "Write", "Bash"],
            denied: ["Bash(rm:*)"],
            permissionMode: "acceptEdits",
            subscriptions: ["build.failed", "pr.opened"],
            mcpServers: ["kiteloop-tools", "github"],
            skills: ["review", "simplify"],
            avatar: "🧙‍♂️",
            group: "engineering",
            effort: "high",
            maxBudgetUSD: 12.5,
            thinkingEnabled: true,
            thinkingBudget: 8000,
            crossAgentAccess: ["reviewer", "planner"],
            canAcceptDelegation: true,
            runtimeKind: "claude",
            workspacePath: "/Users/dev/proj",
            mcpConfigPath: "/Users/dev/proj/.kiteloop/mcp.json",
            operatorToolsEnabled: true,
            state: state
        )
    }

    private func assertEqualFieldByField(_ decoded: Agent, _ original: Agent, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(decoded.id, original.id, "id", file: file, line: line)
        XCTAssertEqual(decoded.name, original.name, "name", file: file, line: line)
        XCTAssertEqual(decoded.model, original.model, "model", file: file, line: line)
        XCTAssertEqual(decoded.systemPrompt, original.systemPrompt, "systemPrompt", file: file, line: line)
        XCTAssertEqual(decoded.tools, original.tools, "tools", file: file, line: line)
        XCTAssertEqual(decoded.denied, original.denied, "denied", file: file, line: line)
        XCTAssertEqual(decoded.permissionMode, original.permissionMode, "permissionMode", file: file, line: line)
        XCTAssertEqual(decoded.subscriptions, original.subscriptions, "subscriptions", file: file, line: line)
        XCTAssertEqual(decoded.mcpServers, original.mcpServers, "mcpServers", file: file, line: line)
        XCTAssertEqual(decoded.skills, original.skills, "skills", file: file, line: line)
        XCTAssertEqual(decoded.avatar, original.avatar, "avatar", file: file, line: line)
        XCTAssertEqual(decoded.group, original.group, "group", file: file, line: line)
        XCTAssertEqual(decoded.effort, original.effort, "effort", file: file, line: line)
        XCTAssertEqual(decoded.maxBudgetUSD, original.maxBudgetUSD, "maxBudgetUSD", file: file, line: line)
        XCTAssertEqual(decoded.thinkingEnabled, original.thinkingEnabled, "thinkingEnabled", file: file, line: line)
        XCTAssertEqual(decoded.thinkingBudget, original.thinkingBudget, "thinkingBudget", file: file, line: line)
        XCTAssertEqual(decoded.crossAgentAccess, original.crossAgentAccess, "crossAgentAccess", file: file, line: line)
        XCTAssertEqual(decoded.canAcceptDelegation, original.canAcceptDelegation, "canAcceptDelegation", file: file, line: line)
        XCTAssertEqual(decoded.runtimeKind, original.runtimeKind, "runtimeKind", file: file, line: line)
        XCTAssertEqual(decoded.workspacePath, original.workspacePath, "workspacePath", file: file, line: line)
        XCTAssertEqual(decoded.mcpConfigPath, original.mcpConfigPath, "mcpConfigPath", file: file, line: line)
        XCTAssertEqual(decoded.operatorToolsEnabled, original.operatorToolsEnabled, "operatorToolsEnabled", file: file, line: line)
        XCTAssertEqual(decoded.state, original.state, "state", file: file, line: line)
    }

    // MARK: - Round-trip

    func testFullyPopulatedAgentRoundTrips() throws {
        let original = fullAgent()

        let decoded = try roundTrip(original)

        // Field-by-field first: a failure names the lost key instead of dumping two structs.
        assertEqualFieldByField(decoded, original)
        XCTAssertEqual(decoded, original)
    }

    /// Optionals left nil must come back nil, not as an empty string or a default.
    func testAgentWithAllOptionalsNilRoundTrips() throws {
        let original = Agent(
            id: "agent-minimal",
            name: "Minimal",
            model: "sonnet",
            systemPrompt: "",
            tools: [],
            denied: [],
            permissionMode: "default",
            state: .idle
        )

        let decoded = try roundTrip(original)

        XCTAssertEqual(decoded, original)
        XCTAssertNil(decoded.avatar)
        XCTAssertNil(decoded.group)
        XCTAssertNil(decoded.effort)
        XCTAssertNil(decoded.maxBudgetUSD)
        XCTAssertNil(decoded.thinkingBudget)
        XCTAssertNil(decoded.runtimeKind)
        XCTAssertNil(decoded.workspacePath)
        XCTAssertNil(decoded.mcpConfigPath)
    }

    func testDefaultCoderRoundTrips() throws {
        let decoded = try roundTrip(Agent.defaultCoder)

        XCTAssertEqual(decoded, Agent.defaultCoder)
    }

    /// The round-trip must be idempotent — a second cycle cannot drift further.
    func testRoundTripIsStableAcrossTwoCycles() throws {
        let once = try roundTrip(fullAgent())
        let twice = try roundTrip(once)

        XCTAssertEqual(twice, once)
        XCTAssertEqual(try encoder().encode(twice), try encoder().encode(once))
    }

    func testEveryAgentStateRoundTrips() throws {
        for state in [Agent.AgentState.idle, .working, .waitingForHuman, .crashed] {
            let decoded = try roundTrip(fullAgent(state: state))

            XCTAssertEqual(decoded.state, state, "state \(state)")
        }
    }

    /// Ordering carries meaning: `tools` becomes CLI flags and `denied` is matched
    /// in order, so the arrays must not be reordered or de-duplicated by a round-trip.
    func testArrayOrderAndDuplicatesArePreserved() throws {
        var original = fullAgent()
        original.tools = ["Write", "Read", "Bash", "Read"]
        original.denied = ["Glob", "Read"]

        let decoded = try roundTrip(original)

        XCTAssertEqual(decoded.tools, ["Write", "Read", "Bash", "Read"])
        XCTAssertEqual(decoded.denied, ["Glob", "Read"])
    }

    /// System prompts are free-form user text — newlines, quotes and emoji must survive
    /// intact, since they are passed straight through to the CLI.
    func testUnicodeAndMultilineTextRoundTrips() throws {
        var original = fullAgent()
        original.name = "Ravn 🦅"
        original.systemPrompt = "Line one\nLine \"two\"\n\tTabbed — em-dash, emoji 🧑‍🚀"
        original.avatar = "🧝‍♀️"

        let decoded = try roundTrip(original)

        XCTAssertEqual(decoded.name, original.name)
        XCTAssertEqual(decoded.systemPrompt, original.systemPrompt)
        XCTAssertEqual(decoded.avatar, original.avatar)
    }

    // MARK: - Wire format

    /// The key names are the on-disk/on-wire contract; renaming one silently drops the
    /// field on read, so pin the exact set an encode emits.
    func testEncodedKeysMatchTheDeclaredCodingKeys() throws {
        let expected: Set<String> = [
            "id", "name", "model", "systemPrompt", "tools", "denied",
            "permissionMode", "subscriptions", "mcpServers", "skills", "avatar", "group",
            "effort", "maxBudgetUSD", "thinkingEnabled", "thinkingBudget",
            "crossAgentAccess", "canAcceptDelegation", "runtimeKind", "workspacePath",
            "mcpConfigPath", "operatorToolsEnabled", "state",
        ]

        XCTAssertEqual(try keys(of: fullAgent()), expected)
    }

    /// Synthesized encoding uses `encodeIfPresent` for optionals, so nil fields are absent
    /// rather than `null` — the decoder must treat both the same (see the `null` test below).
    func testNilOptionalsAreOmittedFromTheEncodedPayload() throws {
        let agent = Agent(
            id: "agent-minimal",
            name: "Minimal",
            model: "sonnet",
            systemPrompt: "",
            tools: [],
            denied: [],
            permissionMode: "default",
            state: .idle
        )

        let emitted = try keys(of: agent)

        for absent in ["avatar", "group", "effort", "maxBudgetUSD", "thinkingBudget",
                       "runtimeKind", "workspacePath", "mcpConfigPath"] {
            XCTAssertFalse(emitted.contains(absent), "\(absent) should be omitted when nil")
        }
        // Non-optional fields are always written, even at their default value.
        for present in ["tools", "thinkingEnabled", "canAcceptDelegation", "operatorToolsEnabled", "state"] {
            XCTAssertTrue(emitted.contains(present), "\(present) should always be emitted")
        }
    }

    func testAgentStateEncodesAsItsRawString() throws {
        let agent = fullAgent(state: .waitingForHuman)

        let object = try JSONSerialization.jsonObject(with: encoder().encode(agent))
        let dict = try XCTUnwrap(object as? [String: Any])

        XCTAssertEqual(dict["state"] as? String, "waitingForHuman")
    }

    // MARK: - Forgiving decode

    /// Only `name` is required; everything else must land on the documented default.
    func testNameOnlyPayloadDecodesToDefaults() throws {
        let agent = try decode(#"{ "name": "Solo" }"#)

        XCTAssertEqual(agent.name, "Solo")
        XCTAssertEqual(agent.model, "sonnet")
        XCTAssertEqual(agent.systemPrompt, "")
        XCTAssertEqual(agent.tools, [])
        XCTAssertEqual(agent.denied, [])
        XCTAssertEqual(agent.permissionMode, "auto")
        XCTAssertEqual(agent.subscriptions, [])
        XCTAssertEqual(agent.mcpServers, [])
        XCTAssertEqual(agent.skills, [])
        XCTAssertEqual(agent.crossAgentAccess, [])
        XCTAssertFalse(agent.thinkingEnabled)
        XCTAssertFalse(agent.canAcceptDelegation)
        XCTAssertFalse(agent.operatorToolsEnabled)
        XCTAssertEqual(agent.state, .idle)
        XCTAssertNil(agent.avatar)
        XCTAssertNil(agent.runtimeKind)
    }

    /// A missing `id` is filled with a fresh UUID rather than failing — but the two agents
    /// must not collide, since `id` keys the session map.
    func testMissingIDGetsAFreshUniqueUUID() throws {
        let first = try decode(#"{ "name": "Solo" }"#)
        let second = try decode(#"{ "name": "Solo" }"#)

        XCTAssertNotEqual(first.id, second.id)
        XCTAssertNotNil(UUID(uuidString: first.id))
        XCTAssertNotNil(UUID(uuidString: second.id))
    }

    func testMissingNameIsAHardFailure() {
        XCTAssertThrowsError(try decode(#"{ "id": "nameless", "model": "opus" }"#)) { error in
            guard case DecodingError.keyNotFound(let key, _) = error else {
                return XCTFail("expected keyNotFound, got \(error)")
            }
            XCTAssertEqual(key.stringValue, "name")
        }
    }

    /// Explicit `null` is the shape a hand-edited file or a JS client produces; it must be
    /// treated exactly like an absent key, not as a decode failure.
    func testExplicitNullsFallBackToTheSameDefaultsAsMissingKeys() throws {
        let agent = try decode("""
        {
          "id": null, "name": "Nullish", "model": null, "systemPrompt": null,
          "tools": null, "autoApproved": null, "denied": null, "permissionMode": null,
          "subscriptions": null, "mcpServers": null, "skills": null, "avatar": null,
          "group": null, "effort": null, "maxBudgetUSD": null, "thinkingEnabled": null,
          "thinkingBudget": null, "autoMode": null, "crossAgentAccess": null,
          "canAcceptDelegation": null, "runtimeKind": null, "workspacePath": null,
          "mcpConfigPath": null, "operatorToolsEnabled": null, "state": null
        }
        """)

        XCTAssertEqual(agent.name, "Nullish")
        XCTAssertEqual(agent.model, "sonnet")
        XCTAssertEqual(agent.permissionMode, "auto")
        XCTAssertEqual(agent.state, .idle)
        XCTAssertEqual(agent.tools, [])
        XCTAssertFalse(agent.operatorToolsEnabled)
        XCTAssertNil(agent.avatar)
        XCTAssertNotNil(UUID(uuidString: agent.id))
    }

    /// Unknown keys are ignored, so a config written by a newer build still loads.
    func testUnknownKeysAreIgnored() throws {
        let agent = try decode("""
        { "name": "Forward", "model": "opus", "futureFlag": true, "nested": { "a": 1 } }
        """)

        XCTAssertEqual(agent.name, "Forward")
        XCTAssertEqual(agent.model, "opus")
    }

    /// An agent whose file names no permission mode runs in Claude Code's auto
    /// mode — the app's default — rather than one that would prompt nobody.
    func testAnAgentWithNoModeSetDecodesAsAuto() throws {
        let agent = try decode(#"{ "name": "Unset", "denied": ["WebSearch"] }"#)

        XCTAssertEqual(agent.permissionMode, "auto")
        XCTAssertEqual(ClaudeCodeCLIRuntime.permissionArguments(agent: agent, unattended: false),
                       ["--permission-mode", "auto", "--permission-prompts", "host",
                        "--permission-prompt-tool", "stdio", "--disallowedTools", "WebSearch"])
    }

    /// An `agent.json` written before auto mode and the auto-approved list were
    /// removed still loads: both keys are now unknown, so they are ignored and
    /// the mode and the deny list — what the harness reads — survive intact.
    func testTheRemovedPermissionKeysAreIgnoredOnDecode() throws {
        let agent = try decode("""
        { "name": "Legacy", "permissionMode": "plan", "denied": ["Bash"],
          "autoApproved": ["Read", "Glob"], "autoMode": true }
        """)

        XCTAssertEqual(agent.name, "Legacy")
        XCTAssertEqual(agent.permissionMode, "plan")
        XCTAssertEqual(agent.denied, ["Bash"])
    }

    /// A `state` value this build does not know is a real failure, not a silent `.idle` —
    /// `decodeIfPresent` only tolerates absent/`null`, never a bad raw value.
    func testUnknownStateRawValueThrows() {
        XCTAssertThrowsError(try decode(#"{ "name": "Solo", "state": "hibernating" }"#)) { error in
            guard case DecodingError.dataCorrupted = error else {
                return XCTFail("expected dataCorrupted, got \(error)")
            }
        }
    }

    func testWrongTypeForAKnownKeyThrows() {
        XCTAssertThrowsError(try decode(#"{ "name": "Solo", "tools": "Read" }"#))
        XCTAssertThrowsError(try decode(#"{ "name": "Solo", "thinkingEnabled": "yes" }"#))
    }

    /// Budgets are hand-typed as bare integers as often as decimals; both must decode.
    func testMaxBudgetAcceptsIntegerAndDecimalLiterals() throws {
        XCTAssertEqual(try decode(#"{ "name": "A", "maxBudgetUSD": 5 }"#).maxBudgetUSD, 5)
        XCTAssertEqual(try decode(#"{ "name": "A", "maxBudgetUSD": 5.25 }"#).maxBudgetUSD, 5.25)
    }

    /// A sparse payload must survive re-encoding: decode → encode → decode lands on the
    /// same agent, which is what makes "load, tweak one field, save" non-destructive.
    func testSparsePayloadIsStableOnceDecoded() throws {
        let first = try decode(#"{ "id": "sparse", "name": "Sparse", "tools": ["Read"] }"#)

        let second = try roundTrip(first)

        XCTAssertEqual(second, first)
    }

    // MARK: - resolvedRuntimeKind

    /// `runtimeKind` survives a round-trip as a raw string, and the resolution from model
    /// name still applies afterwards — a decoded agent picks the same runtime as a live one.
    func testResolvedRuntimeKindSurvivesRoundTrip() throws {
        let cases: [(runtimeKind: String?, model: String, expected: RuntimeKind)] = [
            ("ollama", "opus", .ollama),
            ("copilot", "sonnet", .copilot),
            (nil, "llama3.1:70b", .ollama),
            (nil, "copilot-gpt-4", .copilot),
            (nil, "sonnet", .claude),
            ("not-a-runtime", "sonnet", .claude),
        ]

        for testCase in cases {
            var original = fullAgent()
            original.runtimeKind = testCase.runtimeKind
            original.model = testCase.model

            let decoded = try roundTrip(original)

            XCTAssertEqual(decoded.runtimeKind, testCase.runtimeKind, "runtimeKind for \(testCase.model)")
            XCTAssertEqual(decoded.resolvedRuntimeKind, testCase.expected, "resolved for \(testCase.model)")
        }
    }
}
