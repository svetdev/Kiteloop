import XCTest
import KiteloopCore
@testable import Kiteloop

final class AgentCardServiceTests: XCTestCase {

    private func makeTestTemplate(id: String = "test-agent", name: String = "Test Agent") -> AgentTemplate {
        AgentTemplate(
            id: id,
            name: name,
            model: "sonnet",
            systemPrompt: "You are a test agent",
            tools: ["Read", "Write", "Bash"],
            skills: ["tdd", "debugging"],
            description: "Handles code review and testing"
        )
    }

    func testCardGenerationFromTemplate() async throws {
        let tmpDir = try makeTemporaryDirectory(prefix: "card-test")
        let agentDir = tmpDir.appending(path: "agents/test-agent")
        let knowledgeDir = agentDir.appending(path: "knowledge/testing")
        try! FileManager.default.createDirectory(at: knowledgeDir, withIntermediateDirectories: true)
        try! "---\nname: Test Agent\ndescription: Code review expert\n---\nPrompt".write(to: agentDir.appending(path: "profile.md"), atomically: true, encoding: .utf8)
        try! "Test content".write(to: knowledgeDir.appending(path: "guide.md"), atomically: true, encoding: .utf8)

        let knowledgeStore = AgentKnowledgeStore(baseURL: tmpDir)
        let template = makeTestTemplate()
        let service = AgentCardService(knowledgeStore: knowledgeStore)

        let ref = AgentRef(id: "test-agent", scope: .global)
        let card = await service.generateCard(for: ref, template: template)

        XCTAssertEqual(card.name, "Test Agent")
        XCTAssertEqual(card.model, "sonnet")
        XCTAssertTrue(card.toolsUsed.contains("Read"))
        XCTAssertTrue(card.knowledgeDomains.contains("testing"))
        XCTAssertFalse(card.sourceFingerprint.isEmpty)
    }

    func testCacheHitReturnsSameCard() async throws {
        let tmpDir = try makeTemporaryDirectory(prefix: "card-test")
        try! FileManager.default.createDirectory(at: tmpDir.appending(path: "agents"), withIntermediateDirectories: true)

        let knowledgeStore = AgentKnowledgeStore(baseURL: tmpDir)
        let template = makeTestTemplate()
        let service = AgentCardService(knowledgeStore: knowledgeStore)

        let ref = AgentRef(id: "test-agent", scope: .global)
        let card1 = await service.generateCard(for: ref, template: template)
        let card2 = await service.generateCard(for: ref, template: template)

        XCTAssertEqual(card1.sourceFingerprint, card2.sourceFingerprint)
    }

    func testCacheInvalidation() async throws {
        let tmpDir = try makeTemporaryDirectory(prefix: "card-test")
        try! FileManager.default.createDirectory(at: tmpDir.appending(path: "agents"), withIntermediateDirectories: true)

        let knowledgeStore = AgentKnowledgeStore(baseURL: tmpDir)
        let template = makeTestTemplate()
        let service = AgentCardService(knowledgeStore: knowledgeStore)

        let ref = AgentRef(id: "test-agent", scope: .global)
        _ = await service.generateCard(for: ref, template: template)

        await service.invalidate(agentRef: ref)
        let cacheSize = await service.cacheCount
        XCTAssertEqual(cacheSize, 0)
    }

    func testDiscoverFiltersMatchingCapabilities() async throws {
        let tmpDir = try makeTemporaryDirectory(prefix: "card-test")
        try! FileManager.default.createDirectory(at: tmpDir.appending(path: "agents"), withIntermediateDirectories: true)

        let knowledgeStore = AgentKnowledgeStore(baseURL: tmpDir)
        let service = AgentCardService(knowledgeStore: knowledgeStore)

        let codeTemplate = makeTestTemplate(id: "code-agent", name: "Code Agent")
        let jiraTemplate = AgentTemplate(id: "jira-agent", name: "Jira Agent", tools: ["jira_create", "jira_search"], description: "Handles Jira ticket triage and sprint management")

        let codeRef = AgentRef(id: "code-agent", scope: .global)
        let jiraRef = AgentRef(id: "jira-agent", scope: .global)

        _ = await service.generateCard(for: codeRef, template: codeTemplate)
        _ = await service.generateCard(for: jiraRef, template: jiraTemplate)

        let results = await service.discover(query: "jira", caller: codeRef, projectID: nil, limit: 10)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.agentRef.id, "jira-agent")
    }
}
