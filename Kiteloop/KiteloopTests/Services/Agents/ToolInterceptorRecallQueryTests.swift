import XCTest
@testable import Kiteloop

/// `recall_knowledge` is dispatched from two places — `ToolInterceptor` and
/// `ChatViewModel.handleRecallKnowledge(input:)` — and they used to read their
/// argument differently: one accepted `topic`, the other refused it. The agent's
/// own memory preamble tells it to call the tool "with a topic name", so the
/// refusing path made memory unreachable for that turn. Both now read through
/// `ToolInterceptor.recallQuery(from:)`, which is what these assert.
final class ToolInterceptorRecallQueryTests: XCTestCase {

    func testReadsQuery() {
        XCTAssertEqual(ToolInterceptor.recallQuery(from: ["query": "worktrees"]), "worktrees")
    }

    /// The spelling `AgentMemoryIndex.preamble` asks for.
    func testReadsTopic() {
        XCTAssertEqual(ToolInterceptor.recallQuery(from: ["topic": "worktrees"]), "worktrees")
    }

    func testPrefersQueryWhenBothPresent() {
        let json: [String: Any] = ["query": "worktrees", "topic": "cost-caps"]
        XCTAssertEqual(ToolInterceptor.recallQuery(from: json), "worktrees")
    }

    func testNilWhenNeitherKeyPresent() {
        XCTAssertNil(ToolInterceptor.recallQuery(from: ["scope": "own"]))
    }

    func testNilForEmptyString() {
        XCTAssertNil(ToolInterceptor.recallQuery(from: ["query": ""]))
        XCTAssertNil(ToolInterceptor.recallQuery(from: ["topic": ""]))
    }

    func testNilForWhitespaceOnly() {
        XCTAssertNil(ToolInterceptor.recallQuery(from: ["query": "   \n\t "]))
        XCTAssertNil(ToolInterceptor.recallQuery(from: ["topic": "   "]))
    }

    func testTrimsSurroundingWhitespace() {
        XCTAssertEqual(ToolInterceptor.recallQuery(from: ["query": "  worktrees\n"]), "worktrees")
        XCTAssertEqual(ToolInterceptor.recallQuery(from: ["topic": " cost-caps "]), "cost-caps")
    }

    /// A blank `query` is no argument at all, so the call is answered from
    /// `topic` rather than refused with a usable argument in hand.
    func testFallsThroughToTopicWhenQueryIsBlank() {
        let json: [String: Any] = ["query": "  ", "topic": "cost-caps"]
        XCTAssertEqual(ToolInterceptor.recallQuery(from: json), "cost-caps")
    }

    /// Arguments arrive as decoded JSON, where a value may be any type.
    func testIgnoresNonStringValues() {
        XCTAssertNil(ToolInterceptor.recallQuery(from: ["query": 42]))
        XCTAssertEqual(ToolInterceptor.recallQuery(from: ["query": 42, "topic": "worktrees"]), "worktrees")
    }

    // MARK: - The schema the agent is shown

    func testSchemaListsTopicAlongsideQuery() throws {
        let properties = try XCTUnwrap(
            KiteloopToolSchemas.recallKnowledge.inputSchema["properties"] as? [String: Any]
        )
        XCTAssertNotNil(properties["topic"])
        XCTAssertNotNil(properties["query"])
        // `query` stays the documented spelling a well-behaved model sends.
        XCTAssertEqual(KiteloopToolSchemas.recallKnowledge.inputSchema["required"] as? [String], ["query"])
    }

    func testSchemaDescriptionSaysMemoryIsSearchedToo() {
        XCTAssertTrue(
            KiteloopToolSchemas.recallKnowledge.description.lowercased().contains("memory"),
            "both handlers also search the agent's memory — the description must say so"
        )
    }
}
