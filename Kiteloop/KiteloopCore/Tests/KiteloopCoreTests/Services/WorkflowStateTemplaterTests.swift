import XCTest
@testable import KiteloopCore

final class WorkflowStateTemplaterTests: XCTestCase {
    func testSimpleInterpolation() {
        let state: [String: AnyCodable] = ["name": .string("Kiteloop"), "count": .int(3)]
        let result = WorkflowStateTemplater.render(
            template: "Hello {{state.name}}, you have {{state.count}} items",
            state: state
        )
        XCTAssertEqual(result.rendered, "Hello Kiteloop, you have 3 items")
        XCTAssertTrue(result.referencedKeys.contains("name"))
        XCTAssertTrue(result.referencedKeys.contains("count"))
    }

    func testMissingKeyLeftAsIs() {
        let state: [String: AnyCodable] = ["name": .string("Kiteloop")]
        let result = WorkflowStateTemplater.render(
            template: "Hello {{state.name}} at {{state.location}}",
            state: state
        )
        XCTAssertEqual(result.rendered, "Hello Kiteloop at {{state.location}}")
        XCTAssertTrue(result.referencedKeys.contains("name"))
        XCTAssertFalse(result.referencedKeys.contains("location"))
    }

    func testNullValueTrackedButNotInterpolated() {
        let state: [String: AnyCodable] = ["name": .string("Kiteloop"), "extra": .null]
        let result = WorkflowStateTemplater.render(
            template: "Hello {{state.name}} with {{state.extra}}",
            state: state
        )
        // extra is in state but .null has no stringValue, so placeholder stays
        XCTAssertEqual(result.rendered, "Hello Kiteloop with {{state.extra}}")
        // BUT extra IS tracked as referenced (critical: insert before guard)
        XCTAssertTrue(result.referencedKeys.contains("extra"))
    }

    func testComplexValueTrackedButNotInterpolated() {
        let state: [String: AnyCodable] = [
            "name": .string("Kiteloop"),
            "items": .array([.string("a"), .string("b")])
        ]
        let result = WorkflowStateTemplater.render(
            template: "Hello {{state.name}} with {{state.items}}",
            state: state
        )
        XCTAssertEqual(result.rendered, "Hello Kiteloop with {{state.items}}")
        // items IS tracked as referenced even though it can't be stringified
        XCTAssertTrue(result.referencedKeys.contains("items"))
    }

    func testStarInjectsRemainder() {
        let state: [String: AnyCodable] = [
            "topic": .string("bugs"),
            "priority": .string("high"),
            "context": .string("extra info")
        ]
        let result = WorkflowStateTemplater.render(
            template: "Research {{state.topic}}. Additional context: {{state.*}}",
            state: state
        )
        XCTAssertTrue(result.rendered.contains("Research bugs"))
        // star injects non-referenced keys as JSON
        XCTAssertTrue(result.rendered.contains("priority"))
        XCTAssertTrue(result.rendered.contains("context"))
        XCTAssertFalse(result.rendered.contains("topic"))
    }

    func testNoPlaceholders() {
        let state: [String: AnyCodable] = ["key": .string("val")]
        let result = WorkflowStateTemplater.render(
            template: "No placeholders here",
            state: state
        )
        XCTAssertEqual(result.rendered, "No placeholders here")
        XCTAssertTrue(result.referencedKeys.isEmpty)
    }

    func testEmptyState() {
        let result = WorkflowStateTemplater.render(
            template: "Hello {{state.name}}",
            state: [:]
        )
        XCTAssertEqual(result.rendered, "Hello {{state.name}}")
    }

    func testConditionalWithStateDotPrefix() {
        let state: [String: AnyCodable] = ["why": .string("performance issue"), "title": .string("Fix lag")]
        let result = WorkflowStateTemplater.render(
            template: "Working on: {{state.title}}\n\n{{#if state.why}}Why: {{state.why}}{{/if}}",
            state: state
        )
        XCTAssertEqual(result.rendered, "Working on: Fix lag\n\nWhy: performance issue")
    }

    func testConditionalWithStateDotPrefixMissingKey() {
        let state: [String: AnyCodable] = ["title": .string("Fix lag")]
        let result = WorkflowStateTemplater.render(
            template: "Working on: {{state.title}}\n\n{{#if state.why}}Why: {{state.why}}{{/if}}",
            state: state
        )
        XCTAssertEqual(result.rendered, "Working on: Fix lag\n\n")
    }

    func testConditionalWithoutPrefix() {
        let state: [String: AnyCodable] = ["feedback": .string("needs more tests")]
        let result = WorkflowStateTemplater.render(
            template: "{{#if feedback}}Feedback: {{state.feedback}}{{/if}}",
            state: state
        )
        XCTAssertEqual(result.rendered, "Feedback: needs more tests")
    }

    func testMultilineConditional() {
        let state: [String: AnyCodable] = ["previousFeedback": .string("fix the auth")]
        let result = WorkflowStateTemplater.render(
            template: "Do the work.\n\n{{#if state.previousFeedback}}\n## Feedback\n{{state.previousFeedback}}\n{{/if}}",
            state: state
        )
        XCTAssertTrue(result.rendered.contains("## Feedback"))
        XCTAssertTrue(result.rendered.contains("fix the auth"))
    }
}
