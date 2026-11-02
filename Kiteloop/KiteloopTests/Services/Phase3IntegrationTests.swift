import XCTest
import KiteloopCore
@testable import Kiteloop

final class Phase3IntegrationTests: XCTestCase {

    func testKnowledgeTiersProgressiveLoading() async throws {
        let tmpDir = try makeTemporaryDirectory(prefix: "p3-int")
        let agentDir = tmpDir.appending(path: "agents/scout")
        let knowledgeDir = agentDir.appending(path: "knowledge/recon")
        try! FileManager.default.createDirectory(at: knowledgeDir, withIntermediateDirectories: true)
        try! "---\nname: Scout\ndescription: Reconnaissance specialist\n---\nYou gather intel.".write(to: agentDir.appending(path: "profile.md"), atomically: true, encoding: .utf8)
        try! "---\ndescription: Enemy formation analysis\n---\n# Formations\nDetailed formation data here.".write(to: knowledgeDir.appending(path: "formations.md"), atomically: true, encoding: .utf8)

        let store = AgentKnowledgeStore(baseURL: tmpDir)
        let service = KnowledgeRecallService(knowledgeStore: store)

        // Tier 1: Identity — lightweight, always available
        let identity = await service.identityTier(for: "scout")
        XCTAssertTrue(identity.contains("Scout"))
        XCTAssertTrue(identity.contains("Reconnaissance specialist"))
        XCTAssertTrue(identity.contains("recon"))
        XCTAssertFalse(identity.contains("Detailed formation data"))

        // Tier 2: Index — manifest, loaded on spawn
        let index = await service.indexTier(for: "scout")
        XCTAssertTrue(index.contains("formations.md"))
        XCTAssertTrue(index.contains("Enemy formation analysis"))
        XCTAssertFalse(index.contains("Detailed formation data"))

        // Tier 3: Full — on-demand via recall
        let full = await service.recall(query: "formation", agentID: "scout")
        XCTAssertTrue(full.contains("Detailed formation data"))

    }

    func testAgentCardGenerationAndDiscovery() async throws {
        let tmpDir = try makeTemporaryDirectory(prefix: "p3-int")
        let agent1Dir = tmpDir.appending(path: "agents/builder")
        let agent2Dir = tmpDir.appending(path: "agents/reviewer")
        try! FileManager.default.createDirectory(at: agent1Dir.appending(path: "knowledge/infra"), withIntermediateDirectories: true)
        try! FileManager.default.createDirectory(at: agent2Dir.appending(path: "knowledge/standards"), withIntermediateDirectories: true)
        try! "---\nname: Builder\ndescription: Builds infrastructure\n---\nPrompt".write(to: agent1Dir.appending(path: "profile.md"), atomically: true, encoding: .utf8)
        try! "---\nname: Reviewer\ndescription: Reviews code and deployments\n---\nPrompt".write(to: agent2Dir.appending(path: "profile.md"), atomically: true, encoding: .utf8)
        try! "Infra knowledge".write(to: agent1Dir.appending(path: "knowledge/infra/k8s.md"), atomically: true, encoding: .utf8)
        try! "Standards knowledge".write(to: agent2Dir.appending(path: "knowledge/standards/style.md"), atomically: true, encoding: .utf8)

        let knowledgeStore = AgentKnowledgeStore(baseURL: tmpDir)
        let cardService = AgentCardService(knowledgeStore: knowledgeStore)

        let builderTemplate = AgentTemplate(id: "builder", name: "Builder", tools: ["Bash", "Write"], description: "Builds infrastructure and deploys services")
        let reviewerTemplate = AgentTemplate(id: "reviewer", name: "Reviewer", tools: ["Read", "Grep"], description: "Reviews code for quality and standards")

        let builderRef = AgentRef(id: "builder", scope: .global)
        let reviewerRef = AgentRef(id: "reviewer", scope: .global)

        let builderCard = await cardService.generateCard(for: builderRef, template: builderTemplate)
        let reviewerCard = await cardService.generateCard(for: reviewerRef, template: reviewerTemplate)

        XCTAssertEqual(builderCard.knowledgeDomains, ["infra"])
        XCTAssertEqual(reviewerCard.knowledgeDomains, ["standards"])
        XCTAssertTrue(builderCard.capabilities.contains("build"))
        XCTAssertTrue(reviewerCard.capabilities.contains("review"))

        // Discovery: reviewer looking for deploy help
        let results = await cardService.discover(query: "deploy", caller: reviewerRef, projectID: nil, limit: 10)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.name, "Builder")

    }
}
