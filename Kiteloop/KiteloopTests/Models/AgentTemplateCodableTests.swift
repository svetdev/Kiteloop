// Kiteloop/KiteloopTests/Models/AgentTemplateCodableTests.swift
import XCTest
import KiteloopCore
@testable import Kiteloop

/// `AgentTemplate` *is* the on-disk team format: `TeamConfigManager.saveTeam` encodes an
/// array of them into a project's `.kiteloop/team.json`, and `ProjectSession`,
/// `TeamConfigWatcher` and `AgentCatalogStore`
/// all decode them back — every one of those readers uses `try?`, so a Codable regression
/// drops a team member silently instead of failing loudly. The decoder is deliberately
/// forgiving (only `name` is required) because the file is hand-editable. These tests pin
/// the round-trip, the key names on the wire, and the defaults a sparse file lands on.
final class AgentTemplateCodableTests: XCTestCase {

    // MARK: - Helpers

    /// Mirrors `TeamConfigManager.saveTeam` — the encoder that actually writes team.json.
    private func teamEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private func roundTrip(_ template: AgentTemplate) throws -> AgentTemplate {
        try JSONDecoder().decode(AgentTemplate.self, from: teamEncoder().encode(template))
    }

    private func decode(_ json: String) throws -> AgentTemplate {
        try JSONDecoder().decode(AgentTemplate.self, from: Data(json.utf8))
    }

    private func keys(of template: AgentTemplate) throws -> Set<String> {
        let object = try JSONSerialization.jsonObject(with: teamEncoder().encode(template))
        return Set(try XCTUnwrap(object as? [String: Any]).keys)
    }

    /// Every field set to a non-default value, so a dropped key surfaces as a mismatch
    /// rather than coinciding with the decoder's fallback.
    private func fullTemplate(id: String = "template-full") -> AgentTemplate {
        AgentTemplate(
            id: id,
            name: "Reviewer",
            model: "opus",
            systemPrompt: "You review diffs against the rubric.",
            tools: ["Read", "Grep", "Bash"],
            denied: ["Write"],
            permissionMode: "acceptEdits",
            subscriptions: ["pr.opened"],
            mcpServers: ["kiteloop-tools"],
            skills: ["review"],
            description: "Blocks work that misses the Definition-of-Done.",
            avatar: "🦉",
            group: "quality",
            runtimeKind: "claude",
            crossAgentAccess: ["Coder", "Planner"],
            operatorToolsEnabled: true
        )
    }

    /// `AgentTemplate` is not Equatable, so round-trip assertions compare field by field —
    /// a failure then names the lost key directly.
    private func assertEqualFieldByField(
        _ decoded: AgentTemplate,
        _ original: AgentTemplate,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
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
        XCTAssertEqual(decoded.description, original.description, "description", file: file, line: line)
        XCTAssertEqual(decoded.avatar, original.avatar, "avatar", file: file, line: line)
        XCTAssertEqual(decoded.group, original.group, "group", file: file, line: line)
        XCTAssertEqual(decoded.runtimeKind, original.runtimeKind, "runtimeKind", file: file, line: line)
        XCTAssertEqual(decoded.crossAgentAccess, original.crossAgentAccess, "crossAgentAccess", file: file, line: line)
        XCTAssertEqual(decoded.operatorToolsEnabled, original.operatorToolsEnabled, "operatorToolsEnabled", file: file, line: line)
    }

    // MARK: - Round-trip

    func testFullyPopulatedTemplateRoundTrips() throws {
        let original = fullTemplate()

        let decoded = try roundTrip(original)

        assertEqualFieldByField(decoded, original)
    }

    /// Optionals left nil must come back nil, not as an empty string.
    func testTemplateWithAllOptionalsNilRoundTrips() throws {
        let original = AgentTemplate(id: "template-minimal", name: "Minimal")

        let decoded = try roundTrip(original)

        assertEqualFieldByField(decoded, original)
        XCTAssertNil(decoded.avatar)
        XCTAssertNil(decoded.group)
        XCTAssertNil(decoded.runtimeKind)
        XCTAssertEqual(decoded.description, "")
    }

    func testRoundTripIsStableAcrossTwoCycles() throws {
        let once = try roundTrip(fullTemplate())
        let twice = try roundTrip(once)

        assertEqualFieldByField(twice, once)
        XCTAssertEqual(try teamEncoder().encode(twice), try teamEncoder().encode(once))
    }

    /// team.json holds an array; the readers decode `[AgentTemplate]` in one shot, so the
    /// whole team — order included — has to survive as a unit.
    func testTeamArrayRoundTripsInOrder() throws {
        let team = [
            fullTemplate(id: "reviewer"),
            AgentTemplate(id: "coder", name: "Coder", model: "sonnet", tools: ["Read", "Edit"]),
            AgentTemplate(id: "planner", name: "Planner", group: "product"),
        ]

        let data = try teamEncoder().encode(team)
        let decoded = try JSONDecoder().decode([AgentTemplate].self, from: data)

        XCTAssertEqual(decoded.map(\.id), ["reviewer", "coder", "planner"])
        for (decodedTemplate, original) in zip(decoded, team) {
            assertEqualFieldByField(decodedTemplate, original)
        }
    }

    /// Ordering carries meaning — `tools` becomes CLI flags — so arrays must not be
    /// reordered or de-duplicated.
    func testArrayOrderAndDuplicatesArePreserved() throws {
        var original = fullTemplate()
        original.tools = ["Write", "Read", "Bash", "Read"]
        original.skills = ["review", "simplify"]

        let decoded = try roundTrip(original)

        XCTAssertEqual(decoded.tools, ["Write", "Read", "Bash", "Read"])
        XCTAssertEqual(decoded.skills, ["review", "simplify"])
    }

    /// Prompts and descriptions are free-form user text written straight into team.json.
    func testUnicodeAndMultilineTextRoundTrips() throws {
        var original = fullTemplate()
        original.name = "Ravn 🦅"
        original.systemPrompt = "Line one\nLine \"two\"\n\tTabbed — em-dash, emoji 🧑‍🚀"
        original.description = "Reviews /diffs/ & \"blocks\" bad work"
        original.avatar = "🧝‍♀️"

        let decoded = try roundTrip(original)

        XCTAssertEqual(decoded.name, original.name)
        XCTAssertEqual(decoded.systemPrompt, original.systemPrompt)
        XCTAssertEqual(decoded.description, original.description)
        XCTAssertEqual(decoded.avatar, original.avatar)
    }

    /// The emoji picker writes these straight into `avatar`; multi-scalar graphemes must
    /// not be mangled on the way through JSON.
    func testEveryDefaultAvatarEmojiRoundTrips() throws {
        for emoji in AgentTemplate.defaultAvatarEmoji {
            var original = fullTemplate()
            original.avatar = emoji

            XCTAssertEqual(try roundTrip(original).avatar, emoji, "avatar \(emoji)")
        }
    }

    // MARK: - Wire format

    /// These key names are the team.json contract shared with hand-edited files; renaming
    /// one silently drops the field on read.
    func testEncodedKeysMatchTheDeclaredFields() throws {
        let expected: Set<String> = [
            "id", "name", "model", "systemPrompt", "tools", "denied", "askFirst",
            "permissionMode", "subscriptions", "mcpServers", "skills", "description",
            "avatar", "group", "runtimeKind", "crossAgentAccess", "operatorToolsEnabled",
        ]

        XCTAssertEqual(try keys(of: fullTemplate()), expected)
    }

    /// Synthesized encoding uses `encodeIfPresent`, so nil optionals are absent rather than
    /// `null` — that keeps a hand-edited team.json readable.
    func testNilOptionalsAreOmittedFromTheEncodedPayload() throws {
        let emitted = try keys(of: AgentTemplate(id: "template-minimal", name: "Minimal"))

        for absent in ["avatar", "group", "runtimeKind"] {
            XCTAssertFalse(emitted.contains(absent), "\(absent) should be omitted when nil")
        }
        for present in ["id", "name", "model", "tools", "description", "permissionMode"] {
            XCTAssertTrue(emitted.contains(present), "\(present) should always be emitted")
        }
    }

    // MARK: - Forgiving decode

    /// Only `name` is required; everything else must land on the documented default.
    func testNameOnlyPayloadDecodesToDefaults() throws {
        let template = try decode(#"{ "name": "Solo" }"#)

        XCTAssertEqual(template.name, "Solo")
        XCTAssertEqual(template.model, "sonnet")
        XCTAssertEqual(template.systemPrompt, "")
        XCTAssertEqual(template.tools, [])
        XCTAssertEqual(template.denied, [])
        XCTAssertEqual(template.permissionMode, "auto")
        XCTAssertEqual(template.subscriptions, [])
        XCTAssertEqual(template.mcpServers, [])
        XCTAssertEqual(template.skills, [])
        XCTAssertEqual(template.description, "")
        XCTAssertNil(template.avatar)
        XCTAssertNil(template.group)
        XCTAssertNil(template.runtimeKind)
        XCTAssertEqual(template.crossAgentAccess, [])
        XCTAssertFalse(template.operatorToolsEnabled)
    }

    /// A team.json written before these two fields were persisted carries neither key;
    /// it must still load, with an empty access list and Operator Tools off.
    func testTeamFileWithoutAccessOrOperatorKeysDecodesToDefaults() throws {
        let json = """
        [
          { "id": "coder", "name": "Coder", "tools": ["Read"] },
          { "id": "reviewer", "name": "Reviewer", "model": "opus" }
        ]
        """

        let team = try JSONDecoder().decode([AgentTemplate].self, from: Data(json.utf8))

        XCTAssertEqual(team.count, 2)
        for template in team {
            XCTAssertEqual(template.crossAgentAccess, [], template.name)
            XCTAssertFalse(template.operatorToolsEnabled, template.name)
        }
    }

    func testMissingIDGetsAFreshUniqueUUID() throws {
        let first = try decode(#"{ "name": "Solo" }"#)
        let second = try decode(#"{ "name": "Solo" }"#)

        XCTAssertNotEqual(first.id, second.id)
        XCTAssertNotNil(UUID(uuidString: first.id))
        XCTAssertNotNil(UUID(uuidString: second.id))
    }

    /// Every reader wraps the decode in `try?`, so a missing `name` drops the whole team,
    /// not just the one entry — pin that this is the only required key.
    func testMissingNameIsAHardFailure() {
        XCTAssertThrowsError(try decode(#"{ "id": "nameless", "model": "opus" }"#)) { error in
            guard case DecodingError.keyNotFound(let key, _) = error else {
                return XCTFail("expected keyNotFound, got \(error)")
            }
            XCTAssertEqual(key.stringValue, "name")
        }
    }

    /// Explicit `null` is what a hand-edited file or a JS client produces; it must behave
    /// exactly like an absent key.
    func testExplicitNullsFallBackToTheSameDefaultsAsMissingKeys() throws {
        let template = try decode("""
        {
          "id": null, "name": "Nullish", "model": null, "systemPrompt": null,
          "tools": null, "autoApproved": null, "denied": null, "permissionMode": null,
          "subscriptions": null, "mcpServers": null, "skills": null, "description": null,
          "avatar": null, "group": null, "runtimeKind": null
        }
        """)

        XCTAssertEqual(template.name, "Nullish")
        XCTAssertEqual(template.model, "sonnet")
        XCTAssertEqual(template.permissionMode, "auto")
        XCTAssertEqual(template.description, "")
        XCTAssertEqual(template.tools, [])
        XCTAssertNil(template.avatar)
        XCTAssertNotNil(UUID(uuidString: template.id))
    }

    /// A team.json written by a newer build must still load on an older one.
    func testUnknownKeysAreIgnored() throws {
        let template = try decode("""
        { "name": "Forward", "model": "opus", "effort": "high", "nested": { "a": 1 } }
        """)

        XCTAssertEqual(template.name, "Forward")
        XCTAssertEqual(template.model, "opus")
    }

    func testWrongTypeForAKnownKeyThrows() {
        XCTAssertThrowsError(try decode(#"{ "name": "Solo", "tools": "Read" }"#))
        XCTAssertThrowsError(try decode(#"{ "name": "Solo", "skills": { "a": 1 } }"#))
    }

    /// A hand-written, sparse team.json must survive being loaded and saved again — that
    /// is what makes "edit one agent in the UI" non-destructive to the rest of the file.
    func testHandWrittenTeamFileIsStableThroughLoadAndSave() throws {
        let json = """
        [
          { "id": "coder", "name": "Coder", "tools": ["Read", "Edit", "Write"] },
          { "id": "reviewer", "name": "Reviewer", "model": "opus", "avatar": "🦉", "group": "quality" }
        ]
        """

        let loaded = try JSONDecoder().decode([AgentTemplate].self, from: Data(json.utf8))
        let saved = try teamEncoder().encode(loaded)
        let reloaded = try JSONDecoder().decode([AgentTemplate].self, from: saved)

        XCTAssertEqual(reloaded.count, 2)
        for (reloadedTemplate, original) in zip(reloaded, loaded) {
            assertEqualFieldByField(reloadedTemplate, original)
        }
        XCTAssertEqual(reloaded[0].tools, ["Read", "Edit", "Write"])
        XCTAssertEqual(reloaded[1].avatar, "🦉")
        XCTAssertEqual(reloaded[1].group, "quality")
        // Defaults filled in on the first load are now written explicitly, and stay put.
        XCTAssertEqual(reloaded[0].model, "sonnet")
        XCTAssertEqual(reloaded[0].permissionMode, "auto")
    }

    // MARK: - Agent ↔ template

    /// `saveTeam` persists `AgentTemplate(from: agent)`, and a reload instantiates the agent
    /// back — so the fields that survive that hop are the ones a restart actually keeps.
    func testAgentSnapshotSurvivesEncodeDecodeAndReinstantiation() throws {
        let agent = Agent(
            id: "coder",
            name: "Coder",
            model: "opus",
            systemPrompt: "Write clean, testable code.",
            tools: ["Read", "Edit", "Write"],
            denied: ["Bash(rm:*)"],
            permissionMode: "acceptEdits",
            subscriptions: ["build.failed"],
            skills: ["simplify"],
            avatar: "🧙‍♂️",
            crossAgentAccess: ["Reviewer"],
            operatorToolsEnabled: true,
            state: .working
        )

        let reloaded = try roundTrip(AgentTemplate(from: agent))
        let restored = reloaded.instantiateAgentWithFixedID()

        XCTAssertEqual(restored.id, agent.id)
        XCTAssertEqual(restored.name, agent.name)
        XCTAssertEqual(restored.model, agent.model)
        XCTAssertEqual(restored.systemPrompt, agent.systemPrompt)
        XCTAssertEqual(restored.tools, agent.tools)
        XCTAssertEqual(restored.denied, agent.denied)
        XCTAssertEqual(restored.permissionMode, agent.permissionMode)
        XCTAssertEqual(restored.subscriptions, agent.subscriptions)
        XCTAssertEqual(restored.skills, agent.skills)
        XCTAssertEqual(restored.avatar, agent.avatar)
        // Edit Agent writes these two to the live agent; they used to be dropped here.
        XCTAssertEqual(restored.crossAgentAccess, ["Reviewer"])
        XCTAssertTrue(restored.operatorToolsEnabled)
        // Runtime-only state is not persisted: a restored agent always starts idle.
        XCTAssertEqual(restored.state, .idle)
    }

    /// The snapshot is the mirror of `instantiateAgent()`: an agent that is backed by
    /// another runtime, carries an MCP allowlist or sits in a sidebar group must come
    /// back as itself. These three used to default on the way out, so hiring or firing
    /// anyone rewrote every teammate as a group-less Claude agent with no allowlist.
    func testAgentSnapshotKeepsRuntimeKindMCPServersAndGroup() {
        let agent = Agent(
            id: "critic",
            name: "Copilot Critic",
            model: "copilot-gpt-4o",
            systemPrompt: "Review the plan.",
            tools: [],
            denied: ["Bash"],
            permissionMode: "plan",
            subscriptions: [],
            mcpServers: ["kiteloop-tools", "github"],
            skills: [],
            avatar: "🔍",
            group: "Review",
            runtimeKind: "copilot",
            state: .idle
        )

        let snapshot = AgentTemplate(from: agent)

        XCTAssertEqual(snapshot.runtimeKind, "copilot")
        XCTAssertEqual(snapshot.mcpServers, ["kiteloop-tools", "github"])
        XCTAssertEqual(snapshot.group, "Review")
    }

    /// The same three fields have to survive the write `saveTeam` actually performs —
    /// encode, atomic write, and the decode the next launch does off the file.
    func testSavedTeamFileKeepsRuntimeKindMCPServersAndGroup() throws {
        let root = try makeTemporaryDirectory()
        let project = KiteloopProject(rootURL: root)
        let agent = Agent(
            id: "critic",
            name: "Copilot Critic",
            model: "copilot-gpt-4o",
            systemPrompt: "Review the plan.",
            tools: [],
            denied: [],
            permissionMode: "plan",
            mcpServers: ["kiteloop-tools", "github"],
            group: "Review",
            runtimeKind: "copilot",
            state: .idle
        )

        try TeamConfigManager(project: project).saveTeam([AgentTemplate(from: agent)])
        let written = try Data(contentsOf: project.teamConfigURL)
        let reloaded = try JSONDecoder().decode([AgentTemplate].self, from: written)

        XCTAssertEqual(reloaded.count, 1)
        XCTAssertEqual(reloaded.first?.runtimeKind, "copilot")
        XCTAssertEqual(reloaded.first?.mcpServers, ["kiteloop-tools", "github"])
        XCTAssertEqual(reloaded.first?.group, "Review")
    }

    /// A template loaded from team.json instantiates an agent that carries every persisted
    /// field through, keeping `id` stable so existing sessions still match.
    func testInstantiateWithFixedIDCarriesEveryPersistedField() throws {
        let template = try roundTrip(fullTemplate(id: "reviewer"))

        let agent = template.instantiateAgentWithFixedID()

        XCTAssertEqual(agent.id, "reviewer")
        XCTAssertEqual(agent.name, template.name)
        XCTAssertEqual(agent.model, template.model)
        XCTAssertEqual(agent.systemPrompt, template.systemPrompt)
        XCTAssertEqual(agent.tools, template.tools)
        XCTAssertEqual(agent.denied, template.denied)
        XCTAssertEqual(agent.permissionMode, template.permissionMode)
        XCTAssertEqual(agent.subscriptions, template.subscriptions)
        XCTAssertEqual(agent.mcpServers, template.mcpServers)
        XCTAssertEqual(agent.skills, template.skills)
        XCTAssertEqual(agent.avatar, template.avatar)
        XCTAssertEqual(agent.group, template.group)
        XCTAssertEqual(agent.runtimeKind, template.runtimeKind)
        XCTAssertEqual(agent.crossAgentAccess, template.crossAgentAccess)
        XCTAssertEqual(agent.operatorToolsEnabled, template.operatorToolsEnabled)
        XCTAssertEqual(agent.state, .idle)
    }

    /// `instantiateAgent` is the "hire a second copy" path — same fields, fresh `id`.
    func testInstantiateAgentAssignsAFreshID() throws {
        let template = try roundTrip(fullTemplate(id: "reviewer"))

        let first = template.instantiateAgent()
        let second = template.instantiateAgent()

        XCTAssertNotEqual(first.id, "reviewer")
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertNotNil(UUID(uuidString: first.id))
        XCTAssertEqual(first.name, template.name)
        XCTAssertEqual(first.tools, template.tools)
    }

    func testTheAlwaysAskRulesSurviveTheTeamFileAndReachTheAgent() throws {
        var template = AgentTemplate(id: "desk", name: "Desk")
        template.askFirst = ["Bash(gh pr comment:*)"]

        let decoded = try roundTrip(template)

        XCTAssertEqual(decoded.askFirst, ["Bash(gh pr comment:*)"])
        XCTAssertEqual(decoded.instantiateAgentWithFixedID().askFirst, ["Bash(gh pr comment:*)"])
        XCTAssertEqual(AgentTemplate(from: decoded.instantiateAgent()).askFirst, ["Bash(gh pr comment:*)"])
        XCTAssertEqual(try decode(#"{ "name": "Old" }"#).askFirst, [], "a team file from before the field asks about nothing")
    }
}
