import XCTest
@testable import Kiteloop

/// The `save_knowledge` schema documented `category` while the handler demanded
/// `type`, so a call shaped like the schema was refused every time — and the
/// `type` it did accept went onto the knowledge directory as a path component
/// unchecked. `ToolInterceptor.saveKnowledgeArguments(from:)` reads both
/// spellings and lets through only a kind from the fixed set.
final class ToolInterceptorSaveKnowledgeArgumentsTests: XCTestCase {
    private func parse(_ json: [String: Any]) throws -> ToolInterceptor.SaveKnowledgeArguments {
        try ToolInterceptor.saveKnowledgeArguments(from: json)
    }

    private func assertRefused(_ json: [String: Any], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try parse(json), file: file, line: line) { error in
            for kind in ToolInterceptor.saveKnowledgeKinds {
                XCTAssertTrue(error.localizedDescription.contains(kind),
                              "refusal should list \(kind): \(error.localizedDescription)", file: file, line: line)
            }
        }
    }

    func testTheShapeTheSchemaAdvertisesIsAccepted() {
        XCTAssertEqual(try parse(["content": "a fact", "category": "decision"]),
                       .init(content: "a fact", kind: "decision"))
    }

    func testTypeIsAccepted() {
        XCTAssertEqual(try parse(["content": "a fact", "type": "observation"]),
                       .init(content: "a fact", kind: "observation"))
    }

    func testTypeWinsWhenBothArePresent() {
        XCTAssertEqual(try parse(["content": "a fact", "type": "pattern", "category": "context"]).kind,
                       "pattern")
    }

    func testTheKindIsTrimmedAndLowercased() {
        XCTAssertEqual(try parse(["content": "a fact", "category": "  Reference\n"]).kind, "reference")
    }

    func testMissingContentIsRefused() {
        XCTAssertThrowsError(try parse(["category": "decision"]))
    }

    func testAnUnknownKindIsRefused() {
        assertRefused(["content": "a fact", "category": "gossip"])
    }

    func testAnEmptyOrMissingKindIsRefused() {
        assertRefused(["content": "a fact", "category": "   "])
        assertRefused(["content": "a fact"])
    }

    func testAKindWithAPathSeparatorOrDotDotIsRefused() {
        assertRefused(["content": "a fact", "type": "../../../escape"])
        assertRefused(["content": "a fact", "category": "decision/../../x"])
        assertRefused(["content": "a fact", "type": ".."])
    }

    /// The schema's `category` description names exactly the kinds the parser
    /// accepts, so the two cannot drift apart again.
    func testTheSchemaCategoryNamesExactlyTheAcceptedKinds() throws {
        let schema = KiteloopToolSchemas.saveKnowledge.inputSchema
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        let category = try XCTUnwrap(properties["category"] as? [String: Any])
        let description = try XCTUnwrap(category["description"] as? String)
        let listed = try XCTUnwrap(description.split(separator: ":", maxSplits: 1).last)
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }

        XCTAssertEqual(Set(listed), Set(ToolInterceptor.saveKnowledgeKinds))
        for kind in listed {
            XCTAssertEqual(try parse(["content": "a fact", "category": kind]).kind, kind)
        }
    }

    func testTheSchemaRequiresOnlyWhatTheHandlerReads() throws {
        let required = try XCTUnwrap(KiteloopToolSchemas.saveKnowledge.inputSchema["required"] as? [String])
        XCTAssertFalse(required.contains("title"))
        let properties = try XCTUnwrap(KiteloopToolSchemas.saveKnowledge.inputSchema["properties"] as? [String: Any])
        XCTAssertNil(properties["title"])
        XCTAssertNotNil(properties["type"])
    }
}
