import XCTest
@testable import KiteloopCore

/// Leniency tests for reviewer-output parsing: a reviewer that answers
/// "passed: true" in almost any shape should route correctly instead of
/// dead-ending the autopilot in the `blocked` node.
final class StructuredOutputExtractorTests: XCTestCase {

    private let reviewerSchema = OutputSchema(fields: [
        "passed": .init(type: "boolean", required: true, description: nil),
        "reason": .init(type: "string", required: true, description: nil),
    ])

    private func passed(_ text: String) -> String? {
        StructuredOutputExtractor.extract(from: text, schema: reviewerSchema)?["passed"]?.stringValue
    }

    private func reason(_ text: String) -> String? {
        StructuredOutputExtractor.extract(from: text, schema: reviewerSchema)?["reason"]?.stringValue
    }

    func testCleanFencedJSON() {
        XCTAssertEqual(passed("Looks good.\n```json\n{\"passed\": true, \"reason\": \"ok\"}\n```"), "true")
    }

    func testInlineFencedJSONWithoutNewlines() {
        XCTAssertEqual(passed("```json {\"passed\": false, \"reason\": \"nope\"}```"), "false")
    }

    func testJSONFollowedByProse() {
        XCTAssertEqual(passed("{\"passed\": true, \"reason\": \"great\"}\n\nNice work overall."), "true")
    }

    func testPartialMissingRequiredSiblingStillRoutes() {
        // Previously dead-ended because `reason` was also marked required.
        XCTAssertEqual(passed("{\"passed\": true}"), "true")
    }

    func testLooseBooleanPhrasing() {
        XCTAssertEqual(passed("{\"passed\": \"yes\", \"reason\": \"x\"}"), "true")
        XCTAssertEqual(passed("{\"passed\": \"FAILED\", \"reason\": \"x\"}"), "false")
    }

    func testBooleanExpressedAsInteger() {
        XCTAssertEqual(passed("{\"passed\": 1, \"reason\": \"x\"}"), "true")
    }

    func testKeyValueFallbackWithoutJSON() {
        XCTAssertEqual(passed("passed: true\nreason: looks solid"), "true")
    }

    func testNumericFieldNotMisreadAsBoolean() {
        let schema = OutputSchema(fields: ["score": .init(type: "number", required: true, description: nil)])
        let out = StructuredOutputExtractor.extract(from: "{\"score\": 1}", schema: schema)
        XCTAssertEqual(out?["score"]?.stringValue, "1", "a numeric 1 must not become \"true\"")
    }

    func testNoStructuredOutputReturnsNil() {
        XCTAssertNil(StructuredOutputExtractor.extract(from: "I have no structured output.", schema: reviewerSchema))
    }

    // MARK: - Malformed JSON

    func testUnclosedFenceStillParses() {
        // The reply got cut off before the closing fence, but the object itself
        // is complete — the balanced-brace scan still finds it.
        XCTAssertEqual(passed("```json\n{\"passed\": false, \"reason\": \"bad\"}"), "false")
    }

    func testTruncatedJSONReturnsNil() {
        // Genuinely unterminated: no closing brace anywhere, and no line-anchored
        // `key: value` to fall back to. Nothing to route on.
        XCTAssertNil(StructuredOutputExtractor.extract(
            from: "```json\n{\"passed\": true, \"reason\": \"looks", schema: reviewerSchema))
        XCTAssertNil(StructuredOutputExtractor.extract(
            from: "{\"passed\": true, \"reason\": \"ok\"", schema: reviewerSchema))
    }

    func testTrailingCommaIsTolerated() {
        XCTAssertEqual(passed("{\"passed\": true, \"reason\": \"ok\",}"), "true")
    }

    func testBraceInsideStringValueDoesNotBreakBalancing() {
        let text = "{\"passed\": false, \"reason\": \"the diff had a {weird} block\"}"
        XCTAssertEqual(passed(text), "false")
        XCTAssertEqual(reason(text), "the diff had a {weird} block")
    }

    func testEscapedQuoteInsideStringValue() {
        let text = "{\"passed\": true, \"reason\": \"said \\\"ok\\\" twice\"}"
        XCTAssertEqual(passed(text), "true")
        XCTAssertEqual(reason(text), "said \"ok\" twice")
    }

    func testSiblingNestedObjectDoesNotDerailScalarFields() {
        XCTAssertEqual(passed("{\"passed\": true, \"reason\": \"x\", \"meta\": {\"a\": {\"b\": 1}}}"), "true")
    }

    // MARK: - Null and non-scalar values

    func testNullFieldIsTreatedAsAbsentRatherThanCrashing() {
        // A JSON `null` used to reach an unguarded JSONSerialization re-encode,
        // which raises an ObjC exception `try?` cannot catch — a hard crash.
        let out = StructuredOutputExtractor.extract(
            from: "{\"passed\": null, \"reason\": \"x\"}", schema: reviewerSchema)
        XCTAssertNil(out?["passed"]?.stringValue, "null carries no verdict")
        XCTAssertEqual(out?["reason"]?.stringValue, "x")
    }

    func testAllNullFieldsReturnNil() {
        XCTAssertNil(StructuredOutputExtractor.extract(from: "{\"passed\": null}", schema: reviewerSchema))
    }

    func testNullReasonStillRoutesOnPassed() {
        XCTAssertEqual(passed("{\"passed\": true, \"reason\": null}"), "true")
    }

    // MARK: - Multiple candidate objects

    func testJunkObjectBeforeTheRealOne() {
        XCTAssertEqual(passed("{\"foo\": 1}\n{\"passed\": true, \"reason\": \"ok\"}"), "true")
    }

    func testJunkObjectAfterTheRealOne() {
        XCTAssertEqual(passed("{\"passed\": true, \"reason\": \"ok\"}\n{\"foo\": 1}"), "true")
    }

    func testSecondFencedBlockWins() {
        let text = "```json\n{\"foo\": 1}\n```\n```json\n{\"passed\": false, \"reason\": \"no\"}\n```"
        XCTAssertEqual(passed(text), "false")
    }

    func testUnparseableFenceFallsBackToKeyValue() {
        XCTAssertEqual(passed("```json\nnot json at all\n```\npassed: no\nreason: broken"), "false")
    }

    // MARK: - Key/value fallback shapes

    func testBulletedKeyValue() {
        XCTAssertEqual(passed("- passed: yes\n- reason: fine"), "true")
    }

    func testKeyValueIsCaseInsensitive() {
        XCTAssertEqual(passed("Passed: TRUE\nReason: fine"), "true")
    }

    func testQuotedKeyValueDropsTrailingProse() {
        let text = "passed: \"true\"\nreason: \"all good\" — nice"
        XCTAssertEqual(passed(text), "true")
        XCTAssertEqual(reason(text), "all good", "the quoted pattern wins over the greedy one")
    }

    func testSingleQuotedJSONFallsBackToKeyValue() {
        // Not valid JSON, and the keys aren't line-anchored — nothing to route on.
        XCTAssertNil(StructuredOutputExtractor.extract(
            from: "{'passed': true, 'reason': 'ok'}", schema: reviewerSchema))
    }

    // MARK: - Non-verdicts

    func testProseMentioningTheKeyIsNotAVerdict() {
        // "passed:" appears mid-sentence, not at the start of a line.
        XCTAssertNil(StructuredOutputExtractor.extract(
            from: "The review passed: everything works.", schema: reviewerSchema))
    }

    func testEmptyAndWhitespaceInputReturnNil() {
        XCTAssertNil(StructuredOutputExtractor.extract(from: "", schema: reviewerSchema))
        XCTAssertNil(StructuredOutputExtractor.extract(from: "   \n\t ", schema: reviewerSchema))
        XCTAssertNil(StructuredOutputExtractor.extract(from: "{}", schema: reviewerSchema))
    }

    func testUnrecognizedBooleanWordIsPassedThroughVerbatim() {
        // Not coerced to a verdict — the edges won't match "maybe", so the run
        // stops rather than guessing.
        XCTAssertEqual(passed("{\"passed\": \"maybe\", \"reason\": \"x\"}"), "maybe")
    }

    func testNumericSchemaKeepsDoublesAndBooleansDistinct() {
        let schema = OutputSchema(fields: ["score": .init(type: "number", required: true, description: nil)])
        XCTAssertEqual(StructuredOutputExtractor.extract(from: "{\"score\": 0.5}", schema: schema)?["score"]?.stringValue, "0.5")
        XCTAssertEqual(StructuredOutputExtractor.extract(from: "{\"score\": true}", schema: schema)?["score"]?.stringValue, "true")
    }
}
