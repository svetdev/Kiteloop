import XCTest
@testable import Kiteloop

final class KnowledgeRecallServiceTests: XCTestCase {

    private func makeKnowledgeStore(baseURL: URL) -> AgentKnowledgeStore {
        AgentKnowledgeStore(baseURL: baseURL)
    }

    func testIdentityTierReturnsNameAndDescription() async throws {
        let tmpDir = try makeTemporaryDirectory(prefix: "kr-test")
        let agentDir = tmpDir.appending(path: "agents/test-agent")
        let knowledgeDir = agentDir.appending(path: "knowledge/jira")
        try! FileManager.default.createDirectory(at: knowledgeDir, withIntermediateDirectories: true)
        try! "---\nname: Test Agent\ndescription: Handles Jira tickets\n---\nYou are a Jira expert.".write(to: agentDir.appending(path: "profile.md"), atomically: true, encoding: .utf8)
        try! "Some knowledge content".write(to: knowledgeDir.appending(path: "guide.md"), atomically: true, encoding: .utf8)

        let store = makeKnowledgeStore(baseURL: tmpDir)
        let service = KnowledgeRecallService(knowledgeStore: store)

        let identity = await service.identityTier(for: "test-agent")
        XCTAssertTrue(identity.contains("Test Agent"))
        XCTAssertTrue(identity.contains("Handles Jira tickets"))
        XCTAssertTrue(identity.contains("jira"))
        XCTAssertTrue(identity.contains("recall_knowledge"))
    }

    func testIdentityTierReturnsEmptyForUnknownAgent() async throws {
        let tmpDir = try makeTemporaryDirectory(prefix: "kr-test")
        try! FileManager.default.createDirectory(at: tmpDir.appending(path: "agents"), withIntermediateDirectories: true)
        let store = makeKnowledgeStore(baseURL: tmpDir)
        let service = KnowledgeRecallService(knowledgeStore: store)

        let identity = await service.identityTier(for: "nonexistent")
        XCTAssertTrue(identity.isEmpty)
    }

    func testRecallReturnsMatchingContent() async throws {
        let tmpDir = try makeTemporaryDirectory(prefix: "kr-test")
        let agentDir = tmpDir.appending(path: "agents/test-agent")
        let knowledgeDir = agentDir.appending(path: "knowledge/workflows")
        try! FileManager.default.createDirectory(at: knowledgeDir, withIntermediateDirectories: true)
        try! "---\nname: Test Agent\ndescription: Workflow expert\n---\nSystem prompt".write(to: agentDir.appending(path: "profile.md"), atomically: true, encoding: .utf8)
        try! "# Sprint Planning\n\nWe run two-week sprints with planning on Mondays.".write(to: knowledgeDir.appending(path: "sprints.md"), atomically: true, encoding: .utf8)
        try! "# Deployments\n\nWe deploy on Thursdays using ArgoCD.".write(to: knowledgeDir.appending(path: "deploys.md"), atomically: true, encoding: .utf8)

        let store = AgentKnowledgeStore(baseURL: tmpDir)
        let service = KnowledgeRecallService(knowledgeStore: store)

        let result = await service.recall(query: "sprint", agentID: "test-agent")
        XCTAssertTrue(result.contains("Sprint Planning"))
        XCTAssertFalse(result.contains("ArgoCD"))
    }

    func testIndexTierGeneratesManifest() async throws {
        let tmpDir = try makeTemporaryDirectory(prefix: "kr-test")
        let agentDir = tmpDir.appending(path: "agents/test-agent")
        let knowledgeDir = agentDir.appending(path: "knowledge/api-contracts")
        try! FileManager.default.createDirectory(at: knowledgeDir, withIntermediateDirectories: true)
        try! "---\nname: Test Agent\ndescription: API expert\n---\nPrompt".write(to: agentDir.appending(path: "profile.md"), atomically: true, encoding: .utf8)
        try! "---\ndescription: Postman collection management\n---\n# Postman\nDetails here.".write(to: knowledgeDir.appending(path: "postman.md"), atomically: true, encoding: .utf8)

        let store = AgentKnowledgeStore(baseURL: tmpDir)
        let service = KnowledgeRecallService(knowledgeStore: store)

        let index = await service.indexTier(for: "test-agent")
        XCTAssertTrue(index.contains("api-contracts"))
        XCTAssertTrue(index.contains("postman.md"))
        XCTAssertTrue(index.contains("Postman collection management"))
    }

    func testIndexTierKeepsSummaryWhenFirstFileHasInvalidUTF8() async throws {
        let tmpDir = try makeTemporaryDirectory(prefix: "kr-test")
        let agentDir = tmpDir.appending(path: "agents/test-agent")
        let contractsDir = agentDir.appending(path: "knowledge/api-contracts")
        let runbooksDir = agentDir.appending(path: "knowledge/runbooks")
        try! FileManager.default.createDirectory(at: contractsDir, withIntermediateDirectories: true)
        try! FileManager.default.createDirectory(at: runbooksDir, withIntermediateDirectories: true)
        try! "---\nname: Test Agent\ndescription: API expert\n---\nPrompt".write(to: agentDir.appending(path: "profile.md"), atomically: true, encoding: .utf8)
        var withFrontmatter = Data("---\ndescription: Postman collection management\n---\n# Postman\n".utf8)
        withFrontmatter.append(0xFF)
        withFrontmatter.append(Data("\nDetails here.".utf8))
        try withFrontmatter.write(to: contractsDir.appending(path: "postman.md"))
        var withoutFrontmatter = Data("Rollback steps ".utf8)
        withoutFrontmatter.append(0xFF)
        withoutFrontmatter.append(Data(" for failed deploys\n\nMore detail.".utf8))
        try withoutFrontmatter.write(to: runbooksDir.appending(path: "rollback.md"))

        let store = AgentKnowledgeStore(baseURL: tmpDir)
        let service = KnowledgeRecallService(knowledgeStore: store)

        let index = await service.indexTier(for: "test-agent")
        XCTAssertTrue(index.contains("postman.md"))
        XCTAssertTrue(index.contains("Postman collection management"))
        XCTAssertTrue(index.contains("rollback.md"))
        XCTAssertTrue(index.contains("for failed deploys"))
    }

    // MARK: - The recall cap

    /// A package with one knowledge file per section, whose bodies are `bodies`.
    ///
    /// Returns the temporary directory so the caller can remove it; the agent is
    /// always `test-agent`.
    private func makePackage(bodies: [String]) throws -> URL {
        let tmpDir = try makeTemporaryDirectory(prefix: "kr-test")
        let agentDir = tmpDir.appending(path: "agents/test-agent")
        let knowledgeDir = agentDir.appending(path: "knowledge/notes")
        try! FileManager.default.createDirectory(at: knowledgeDir, withIntermediateDirectories: true)
        try! "---\nname: Test Agent\ndescription: Note keeper\n---\nSystem prompt"
            .write(to: agentDir.appending(path: "profile.md"), atomically: true, encoding: .utf8)
        for (index, body) in bodies.enumerated() {
            try! body.write(to: knowledgeDir.appending(path: "note-\(index + 1).md"), atomically: true, encoding: .utf8)
        }
        return tmpDir
    }

    /// A query that matches everything used to answer with the whole package —
    /// the unbounded always-injected knowledge the tiers exist to prevent,
    /// arriving through a tool result.
    func testRecallHandsBackAtMostTheCapAndSaysHowManyItWithheld() async throws {
        let bodies = (1...8).map { "# Bedrock tokens expire\n\nbody number \($0)" }
        let tmpDir = try makePackage(bodies: bodies)
        let service = KnowledgeRecallService(knowledgeStore: AgentKnowledgeStore(baseURL: tmpDir))

        let hit = await service.recall(query: "bedrock tokens", agentID: "test-agent")

        let shown = (1...8).filter { hit.contains("body number \($0)") }
        XCTAssertEqual(shown.count, KnowledgeRecallService.maxRecalledSections, hit)
        XCTAssertEqual(shown, [1, 2, 3, 4, 5], hit)
        XCTAssertTrue(
            hit.contains("(3 further sections matched and are not shown here — recall again with a narrower query.)"),
            hit
        )
    }

    func testRecallSaysOneWithheldSectionInTheSingular() async throws {
        let bodies = (1...(KnowledgeRecallService.maxRecalledSections + 1))
            .map { "# Bedrock tokens expire\n\nbody number \($0)" }
        let tmpDir = try makePackage(bodies: bodies)
        let service = KnowledgeRecallService(knowledgeStore: AgentKnowledgeStore(baseURL: tmpDir))

        let hit = await service.recall(query: "bedrock tokens", agentID: "test-agent")

        XCTAssertTrue(
            hit.contains("(1 further section matched and is not shown here — recall again with a narrower query.)"),
            hit
        )
        XCTAssertFalse(hit.contains("sections"), hit)
    }

    /// Under the cap nothing was withheld, so nothing is said about it.
    func testRecallUnderTheCapReturnsEveryMatchAndSaysNothingAboutWithholding() async throws {
        let bodies = (1...3).map { "# Bedrock tokens expire\n\nbody number \($0)" }
            + ["# Sprint planning\n\nMondays."]
        let tmpDir = try makePackage(bodies: bodies)
        let service = KnowledgeRecallService(knowledgeStore: AgentKnowledgeStore(baseURL: tmpDir))

        let hit = await service.recall(query: "bedrock tokens", agentID: "test-agent")

        let shown = (1...3).filter { hit.contains("body number \($0)") }
        XCTAssertEqual(shown, [1, 2, 3], hit)
        XCTAssertFalse(hit.contains("Mondays"), hit)
        XCTAssertFalse(hit.contains("not shown here"), hit)
    }

    /// The single-word fallback is the easy way to match everything — one common
    /// word is enough — so it is capped like the all-words pass.
    func testRecallCapsTheSingleWordFallbackToo() async throws {
        let bodies = (1...9).map { "# Note \($0)\n\nbody number \($0) mentions tokens" }
        let tmpDir = try makePackage(bodies: bodies)
        let service = KnowledgeRecallService(knowledgeStore: AgentKnowledgeStore(baseURL: tmpDir))

        let hit = await service.recall(query: "tokens kubernetes", agentID: "test-agent")

        let shown = (1...9).filter { hit.contains("body number \($0) mentions") }
        XCTAssertEqual(shown.count, KnowledgeRecallService.maxRecalledSections, hit)
        XCTAssertTrue(
            hit.contains("(4 further sections matched and are not shown here — recall again with a narrower query.)"),
            hit
        )
    }

    func testRecallStillSaysNothingMatchedWhenNothingDoes() async throws {
        let tmpDir = try makePackage(bodies: ["# Sprint planning\n\nMondays."])
        let service = KnowledgeRecallService(knowledgeStore: AgentKnowledgeStore(baseURL: tmpDir))

        let miss = await service.recall(query: "kubernetes", agentID: "test-agent")
        XCTAssertEqual(miss, "No knowledge found matching: kubernetes")

        let empty = await service.recall(query: "   ", agentID: "test-agent")
        XCTAssertEqual(empty, "No knowledge found matching:    ")
    }

    // MARK: - Punctuation in the query

    /// A query written the way anyone writes one used to carry its `?` into the
    /// word being looked for, so "worktree isolation?" matched no section on the
    /// all-words pass and fell to the fallback, which answers with every section
    /// saying "worktree" alone.
    func testRecallMatchesEveryWordOfAQueryEndingInPunctuation() async throws {
        let tmpDir = try makePackage(bodies: [
            "# Worktree isolation\n\nEach run gets its own worktree.",
            "# Worktree cleanup\n\nA worktree is removed when it is unchanged."
        ])
        let service = KnowledgeRecallService(knowledgeStore: AgentKnowledgeStore(baseURL: tmpDir))

        let hit = await service.recall(query: "worktree isolation?", agentID: "test-agent")

        XCTAssertTrue(hit.contains("Each run gets its own worktree."), hit)
        XCTAssertFalse(hit.contains("removed when it is unchanged"), hit)
    }

    /// One word plus punctuation used to be a miss outright — nothing contains
    /// "workflows." — so the fallback had nothing to fall back to either.
    func testRecallMatchesAOneWordQueryEndingInPunctuation() async throws {
        let tmpDir = try makePackage(bodies: [
            "# Workflows\n\nA workflow orchestrates subagents.",
            "# Sprint planning\n\nMondays."
        ])
        let service = KnowledgeRecallService(knowledgeStore: AgentKnowledgeStore(baseURL: tmpDir))

        let hit = await service.recall(query: "workflows.", agentID: "test-agent")

        XCTAssertTrue(hit.contains("A workflow orchestrates subagents."), hit)
        XCTAssertFalse(hit.contains("Mondays"), hit)
    }

    /// Only the copy being searched is normalised; the section is handed back as
    /// it is written, punctuation and casing intact.
    func testRecallHandsBackTheSectionVerbatim() async throws {
        let body = "# Bedrock: SSO tokens\n\nThey expire — re-run `aws sso login`, THEN retry."
        let tmpDir = try makePackage(bodies: [body])
        let service = KnowledgeRecallService(knowledgeStore: AgentKnowledgeStore(baseURL: tmpDir))

        let hit = await service.recall(query: "bedrock tokens?", agentID: "test-agent")

        XCTAssertTrue(hit.contains(body), hit)
    }

    /// A query of pure punctuation normalises to no words at all, which is the
    /// empty-query guard the wording already had.
    func testRecallSaysNothingMatchedForAQueryOfOnlyPunctuation() async throws {
        let tmpDir = try makePackage(bodies: ["# Sprint planning\n\nMondays."])
        let service = KnowledgeRecallService(knowledgeStore: AgentKnowledgeStore(baseURL: tmpDir))

        let punctuation = await service.recall(query: "?!,.", agentID: "test-agent")
        XCTAssertEqual(punctuation, "No knowledge found matching: ?!,.")

        let miss = await service.recall(query: "kubernetes?", agentID: "test-agent")
        XCTAssertEqual(miss, "No knowledge found matching: kubernetes?")
    }
}
