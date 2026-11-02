import XCTest
import KiteloopCore
@testable import Kiteloop

/// The two halves of `recall_knowledge` that used to live inside
/// `ChatViewModel.handleRecallKnowledge(input:)`: which knowledge a scope
/// argument opens, and how the entries found are answered back to the agent.
final class ToolInterceptorRecallScopeTests: XCTestCase {

    private func scope(
        _ requested: String,
        access: [String] = []
    ) -> ToolInterceptor.RecallScopeResolution {
        ToolInterceptor.recallScope(requested: requested, agentID: "ada", crossAgentAccess: access)
    }

    func testOwnSearchesOwnAndShared() {
        guard case .scope(.ownAndShared(let agentID)) = scope("own") else {
            return XCTFail("own must resolve to ownAndShared")
        }
        XCTAssertEqual(agentID, "ada")
    }

    func testSharedNeedsNoAccess() {
        guard case .scope(.shared) = scope("shared") else {
            return XCTFail("shared is open to every agent")
        }
    }

    func testAllIsRefusedWithoutCrossAgentAccess() {
        guard case .refusal(let refusal) = scope("all", access: ["grace"]) else {
            return XCTFail("all needs crossAgentAccess: [\"all\"]")
        }
        XCTAssertTrue(refusal.contains("does not have cross-agent access"), refusal)
    }

    func testAllIsAllowedWithCrossAgentAccess() {
        guard case .scope(.all) = scope("all", access: ["all"]) else {
            return XCTFail("crossAgentAccess: [\"all\"] opens every agent's knowledge")
        }
    }

    func testNamedAgentIsRefusedWhenNotListed() {
        guard case .refusal(let refusal) = scope("grace", access: ["turing"]) else {
            return XCTFail("an unlisted agent is not readable")
        }
        XCTAssertTrue(refusal.contains("does not have access to scope 'grace'"), refusal)
        XCTAssertTrue(refusal.contains("own, shared, turing"), refusal)
    }

    func testNamedAgentIsAllowedWhenListed() {
        guard case .scope(.specific(let agentID)) = scope("grace", access: ["grace"]) else {
            return XCTFail("a listed agent is readable")
        }
        XCTAssertEqual(agentID, "grace")
    }

    func testNamedAgentIsAllowedUnderAll() {
        guard case .scope(.specific(let agentID)) = scope("grace", access: ["all"]) else {
            return XCTFail("`all` covers any single agent too")
        }
        XCTAssertEqual(agentID, "grace")
    }

    func testAllIsAllowedWithStarWildcard() {
        guard case .scope(.all) = scope("all", access: ["*"]) else {
            return XCTFail("`*` is the same wildcard as `all`")
        }
    }

    func testNamedAgentIsAllowedUnderStar() {
        guard case .scope(.specific(let agentID)) = scope("grace", access: ["*"]) else {
            return XCTFail("`*` covers any single agent too")
        }
        XCTAssertEqual(agentID, "grace")
    }

    func testAllRefusalNamesBothWildcardSpellings() {
        guard case .refusal(let refusal) = scope("all", access: []) else {
            return XCTFail("an empty list does not open every agent's knowledge")
        }
        XCTAssertTrue(refusal.contains(#"["*"] or ["all"]"#), refusal)
    }

    func testGrantsEveryAgentReadsEitherSpelling() {
        XCTAssertTrue(ToolInterceptor.grantsEveryAgent(["*"]))
        XCTAssertTrue(ToolInterceptor.grantsEveryAgent(["all"]))
        XCTAssertTrue(ToolInterceptor.grantsEveryAgent(["grace", " ALL "]))
    }

    func testGrantsEveryAgentRejectsAListWithoutAWildcard() {
        XCTAssertFalse(ToolInterceptor.grantsEveryAgent([]))
        XCTAssertFalse(ToolInterceptor.grantsEveryAgent(["grace", "turing"]))
        XCTAssertFalse(ToolInterceptor.grantsEveryAgent(["allison", "**"]))
    }

    private func result(_ text: String, score: Double = 0.5) -> KnowledgeIndex.SearchResult {
        KnowledgeIndex.SearchResult(
            filePath: "knowledge/agents/ada/knowledge/pattern/worktrees.md",
            agentID: "ada",
            chunkText: text,
            score: score,
            source: .curated
        )
    }

    func testNothingFoundAndNoMemorySaysSo() {
        let answer = ToolInterceptor.recallAnswer(results: [], query: "worktrees", memory: "")
        XCTAssertEqual(answer, "No relevant knowledge found for query: \"worktrees\"")
    }

    func testNothingFoundFallsBackToMemory() {
        let answer = ToolInterceptor.recallAnswer(results: [], query: "worktrees", memory: "a fact")
        XCTAssertEqual(answer, ToolInterceptor.memorySection("a fact"))
    }

    func testEntriesAreNumberedAndScored() {
        let answer = ToolInterceptor.recallAnswer(
            results: [result("first", score: 0.75), result("second")],
            query: "worktrees",
            memory: ""
        )
        XCTAssertTrue(answer.hasPrefix("Found 2 relevant entries:"), answer)
        XCTAssertTrue(answer.contains("[1] score=0.750 source=curated"), answer)
        XCTAssertTrue(answer.contains("[2] score=0.500"), answer)
        XCTAssertTrue(answer.contains("content: first"), answer)
        XCTAssertFalse(answer.contains("From your memory"), answer)
    }

    func testMemoryIsAppendedAfterTheEntriesItIsNotMistakenFor() {
        let answer = ToolInterceptor.recallAnswer(
            results: [result("first")],
            query: "worktrees",
            memory: "a fact"
        )
        let entries = try? XCTUnwrap(answer.range(of: "content: first"))
        let memory = try? XCTUnwrap(answer.range(of: ToolInterceptor.memorySection("a fact")))
        XCTAssertNotNil(entries)
        XCTAssertNotNil(memory)
        if let entries, let memory { XCTAssertTrue(entries.upperBound <= memory.lowerBound) }
    }

    func testLongEntryContentIsTruncated() {
        let answer = ToolInterceptor.recallAnswer(
            results: [result(String(repeating: "x", count: 600))],
            query: "worktrees",
            memory: ""
        )
        XCTAssertTrue(answer.contains(String(repeating: "x", count: 500)), "500 characters survive")
        XCTAssertFalse(answer.contains(String(repeating: "x", count: 501)), "the 501st does not")
    }
}
