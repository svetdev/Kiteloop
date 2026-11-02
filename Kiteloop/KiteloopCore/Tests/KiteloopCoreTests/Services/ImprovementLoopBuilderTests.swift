import XCTest
@testable import KiteloopCore

/// The builder's prompts are rendered by `WorkflowStateTemplater`, which only
/// substitutes the `{{state.<key>}}` spelling. A bare `{{goal}}` reaches the
/// agent verbatim, so these cases render every prompt in the graph through
/// `WorkflowStateTemplater` — the renderer `WorkflowNodeRunner.prepareActivation`
/// uses, asserted app-side — and assert nothing is left behind.
final class ImprovementLoopBuilderTests: XCTestCase {

    // MARK: - Fixtures

    private func makeContract(requireHumanApproval: Bool = true) -> ImprovementLoopBuilder.Contract {
        ImprovementLoopBuilder.Contract(
            name: "tidy the parser",
            description: "shrink the parser without changing its interface",
            contract: .init(
                scope: ["Sources/Parser/**"],
                frozenInterfaces: ["Sources/Parser/PublicAPI.swift"],
                testCommand: "swift test"
            ),
            goal: "remove the duplicated token scanner",
            agents: .init(implementer: "builder", reviewer: "reviewer"),
            limits: .init(maxIterations: 5, timeoutMinutes: 30, requireHumanApproval: requireHumanApproval)
        )
    }

    /// Everything the graph's prompts refer to, so a leftover span can only be
    /// a misspelled placeholder rather than a key nobody supplied.
    private let populatedState: [String: AnyCodable] = [
        "goal": .string("remove the duplicated token scanner"),
        "changes_summary": .string("folded TokenScanner into Lexer"),
        "files_modified": .string("Sources/Parser/Lexer.swift"),
        "review_feedback": .string("name the new helper after what it returns"),
        "test_output": .string("2 failures in LexerTests"),
    ]

    private func resolvedPrompts(
        requireHumanApproval: Bool = true,
        state: [String: AnyCodable]
    ) -> [String: String] {
        let graph = ImprovementLoopBuilder.build(from: makeContract(requireHumanApproval: requireHumanApproval))
        return graph.nodes.mapValues { node in
            WorkflowStateTemplater.render(template: node.prompt, state: state).rendered
        }
    }

    /// The `{{…}}` spans the templater understands are all gone by the time a
    /// prompt is resolved, so any survivor is an unsubstituted placeholder.
    private func unsubstitutedSpans(in prompt: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: #"\{\{[^}]*\}\}"#)
        let ns = prompt as NSString
        return regex.matches(in: prompt, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) }
    }

    // MARK: - Cases

    func testEveryPromptSubstitutesItsPlaceholders() {
        for (nodeID, prompt) in resolvedPrompts(state: populatedState) {
            XCTAssertEqual(
                unsubstitutedSpans(in: prompt), [],
                "node \(nodeID) left placeholders unsubstituted"
            )
        }
    }

    func testGraphWithoutHumanGateAlsoSubstitutes() {
        let prompts = resolvedPrompts(requireHumanApproval: false, state: populatedState)
        XCTAssertNil(prompts["human-gate"])
        for (nodeID, prompt) in prompts {
            XCTAssertEqual(
                unsubstitutedSpans(in: prompt), [],
                "node \(nodeID) left placeholders unsubstituted"
            )
        }
    }

    func testEachNodeMarksTheOutputsDownstreamReadsAsRequired() {
        // The graph routes on `result`, the implement prompt reads test_output
        // and review_feedback, and the review and done prompts read
        // changes_summary. exit_code and files_modified are best-effort extras
        // a node may omit without stalling anything.
        let graph = ImprovementLoopBuilder.build(from: makeContract())
        func obligations(_ id: String) -> [String: Bool]? {
            graph.nodes[id]?.outputSchema?.fields.mapValues(\.required)
        }
        XCTAssertEqual(obligations("implement"), ["changes_summary": true, "files_modified": false])
        XCTAssertEqual(obligations("test"), ["result": true, "test_output": true, "exit_code": false])
        XCTAssertEqual(obligations("review"), ["result": true, "review_feedback": true])
    }

    func testTheHumanGateInterceptsApprovalWithoutLosingTheRejectLoop() {
        // Requiring approval replaces exactly one edge: review→done becomes
        // review→human-gate→done. A rejection still loops straight back to the
        // coder — dropping that edge would strand every rejected pass.
        let graph = ImprovementLoopBuilder.build(from: makeContract(requireHumanApproval: true))
        XCTAssertFalse(graph.edges.contains { $0.from == "review" && $0.to == "done" })
        let approve = graph.edges.first { $0.from == "review" && $0.to == "human-gate" }
        guard case .outputMatch(_, "approve")? = approve?.condition else {
            return XCTFail("approval does not route review to the human gate")
        }
        XCTAssertTrue(graph.edges.contains { $0.from == "review" && $0.to == "implement" })
        XCTAssertTrue(graph.edges.contains { $0.from == "human-gate" && $0.to == "done" })
    }

    func testImplementPromptCarriesTheGoalText() {
        let prompt = resolvedPrompts(state: populatedState)["implement"]!

        XCTAssertTrue(
            prompt.contains("## Goal\nremove the duplicated token scanner"),
            "the Goal heading is not followed by the goal:\n\(prompt)"
        )
    }

    func testReviewPromptCarriesTheChangesAndNoLongerNamesTestsRun() {
        let prompt = resolvedPrompts(state: populatedState)["review"]!

        XCTAssertTrue(prompt.contains("Summary: folded TokenScanner into Lexer"))
        XCTAssertTrue(prompt.contains("Files: Sources/Parser/Lexer.swift"))
        // No node in this graph writes tests_run: the test node's OutputSchema
        // declares only result, test_output and exit_code.
        XCTAssertFalse(prompt.contains("tests_run"))
    }

    func testDonePromptCarriesGoalChangesAndFeedback() {
        let prompt = resolvedPrompts(state: populatedState)["done"]!

        XCTAssertTrue(prompt.contains("goal=remove the duplicated token scanner"))
        XCTAssertTrue(prompt.contains("changes=folded TokenScanner into Lexer"))
        XCTAssertTrue(prompt.contains("review=name the new helper after what it returns"))
    }

    func testHumanGatePromptCarriesTheChangesSummary() {
        let prompt = resolvedPrompts(state: populatedState)["human-gate"]!

        XCTAssertTrue(prompt.contains("Summary: folded TokenScanner into Lexer"))
    }

    func testSetConditionalExpandsAndUnsetConditionalCollapses() {
        // Only review_feedback is set, so its block expands and the test_output
        // block collapses to nothing.
        let firstPass = resolvedPrompts(state: [
            "goal": .string("g"),
            "review_feedback": .string("name the helper after what it returns"),
        ])["implement"]!

        XCTAssertTrue(firstPass.contains("Reviewer feedback:\nname the helper after what it returns"))
        XCTAssertTrue(firstPass.contains("Address this feedback."))
        XCTAssertFalse(firstPass.contains("Previous test run FAILED:"))
        XCTAssertFalse(firstPass.contains("Fix the failing tests."))

        let secondPass = resolvedPrompts(state: [
            "goal": .string("g"),
            "test_output": .string("2 failures in LexerTests"),
        ])["implement"]!

        XCTAssertTrue(secondPass.contains("Previous test run FAILED:"))
        XCTAssertTrue(secondPass.contains("2 failures in LexerTests"))
        XCTAssertFalse(secondPass.contains("Reviewer feedback:"))
    }
}
