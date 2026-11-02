import XCTest
@testable import KiteloopCore

/// The clean-code loop as a graph: the stages in Robert C. Martin's order, each
/// failure looping back to the coder with the tool's output, the deterministic
/// stages as shell nodes, and every prompt's placeholders substituted by the
/// templater — a bare `{{goal}}` would reach the agent verbatim.
final class CleanCodeLoopBuilderTests: XCTestCase {

    private func makeContract(harden: Bool = true, humanGate: Bool = true) -> CleanCodeLoopBuilder.Contract {
        CleanCodeLoopBuilder.Contract(
            name: "tidy the parser",
            description: "shrink the parser without changing its interface",
            goal: "remove the duplicated token scanner",
            scope: ["Sources/Parser/**"],
            frozenInterfaces: ["Sources/Parser/PublicAPI.swift"],
            testCommand: "swift test",
            cleanCommand: "./quality/bin/check-complexity.sh",
            hardenCommand: harden ? "./quality/bin/mutate.py --all" : "",
            agents: .init(specifier: "spec", implementer: "builder", reviewer: "reviewer", qa: "tester"),
            limits: .init(maxIterations: 6, timeoutMinutes: 90, requireHumanApproval: humanGate)
        )
    }

    private let populatedState: [String: AnyCodable] = [
        "goal": .string("remove the duplicated token scanner"),
        "acceptance": .string("Given a token stream, when scanned twice, then one scanner runs"),
        "qa_procedure": .string("1. run the parser on fixtures/a.txt"),
        "changes_summary": .string("folded TokenScanner into Lexer"),
        "files_modified": .string("Sources/Parser/Lexer.swift"),
        "review_feedback": .string("name the new helper after what it returns"),
        "test_output": .string("2 failures in LexerTests"),
        "qa_report": .string("step 1 passed"),
    ]

    private func unsubstitutedSpans(in prompt: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: #"\{\{[^}]*\}\}"#)
        let ns = prompt as NSString
        return regex.matches(in: prompt, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }

    // MARK: - Shape

    func testTheStagesAreInBobsOrder() {
        let graph = CleanCodeLoopBuilder.build(from: makeContract())
        XCTAssertEqual(graph.entryNode, "specify")
        XCTAssertEqual(graph.terminalNodes, ["done"])
        XCTAssertEqual(Set(graph.nodes.keys),
                       ["specify", "implement", "verify", "clean", "tidy", "harden", "kill-survivors", "review", "qa", "human-gate", "done"])
        func next(_ from: String, _ value: String? = nil) -> String? {
            graph.edges.first { edge in
                guard edge.from == from else { return false }
                switch edge.condition {
                case .always: return value == nil
                case .outputMatch(_, let v): return v == value
                case .humanApproval: return value == "approved"
                default: return false
                }
            }?.to
        }
        XCTAssertEqual(next("specify"), "implement")
        XCTAssertEqual(next("implement"), "verify")
        XCTAssertEqual(next("verify", "pass"), "clean")
        XCTAssertEqual(next("clean", "pass"), "harden")
        XCTAssertEqual(next("harden", "pass"), "review")
        XCTAssertEqual(next("review", "approve"), "qa")
        XCTAssertEqual(next("qa", "pass"), "human-gate")
        XCTAssertEqual(next("human-gate", "approved"), "done")
    }

    func testEveryFailureLoopsBackToTheCoderWithTheToolsOutput() {
        let graph = CleanCodeLoopBuilder.build(from: makeContract())
        func failTarget(_ from: String, _ value: String) -> String? {
            graph.edges.first { $0.from == from && { if case .outputMatch(_, let v) = $0.condition { return v == value }; return false }($0) }?.to
        }
        XCTAssertEqual(failTarget("verify", "fail"), "implement")
        XCTAssertEqual(failTarget("clean", "fail"), "tidy")
        XCTAssertEqual(failTarget("harden", "fail"), "kill-survivors")
        XCTAssertEqual(failTarget("review", "reject"), "implement")
        XCTAssertEqual(failTarget("qa", "fail"), "implement")
        // the repair stages go back through verify, never straight to review
        XCTAssertEqual(graph.edges.first { $0.from == "tidy" }?.to, "verify")
        XCTAssertEqual(graph.edges.first { $0.from == "kill-survivors" }?.to, "verify")
        // the pass edge wins over the fail edge at every fork
        for node in ["verify", "clean", "harden", "review", "qa"] {
            let priorities = graph.edges.filter { $0.from == node }.map(\.priority)
            XCTAssertEqual(priorities.min(), 0, node)
            XCTAssertEqual(priorities.max(), 1, node)
        }
    }

    func testTheDeterministicStagesAreShellNodesRunningTheContractsCommands() {
        let contract = makeContract()
        let graph = CleanCodeLoopBuilder.build(from: contract)
        XCTAssertEqual(graph.nodes["verify"]?.shellCommand, contract.testCommand)
        XCTAssertEqual(graph.nodes["clean"]?.shellCommand, contract.cleanCommand)
        XCTAssertEqual(graph.nodes["harden"]?.shellCommand, contract.hardenCommand)
        for id in ["verify", "clean", "harden"] {
            XCTAssertNil(graph.nodes[id]?.agentID, id)
            XCTAssertNotNil(graph.nodes[id]?.outputSchema?.fields["result"], id)
        }
        XCTAssertNil(graph.nodes["done"]?.agentID, "the terminal is agentless, so the engine finalises it without a turn")
        XCTAssertNil(graph.nodes["done"]?.shellCommand)
    }

    func testEachStageMarksTheOutputsDownstreamReadsAsRequired() {
        // The graph routes on `result`, and the later prompts read the rest:
        // acceptance and qa_procedure feed the coder and QA, changes_summary
        // the reviewer, test_output the repair stages, review_feedback and
        // qa_report the next coder pass. exit_code and files_modified are
        // best-effort extras a stage may omit without stalling anything.
        let graph = CleanCodeLoopBuilder.build(from: makeContract())
        func obligations(_ id: String) -> [String: Bool]? {
            graph.nodes[id]?.outputSchema?.fields.mapValues(\.required)
        }
        XCTAssertEqual(obligations("specify"), ["acceptance": true, "qa_procedure": true])
        XCTAssertEqual(obligations("implement"), ["changes_summary": true, "files_modified": false])
        XCTAssertEqual(obligations("tidy"), ["changes_summary": true])
        XCTAssertEqual(obligations("kill-survivors"), ["changes_summary": true])
        XCTAssertEqual(obligations("review"), ["result": true, "review_feedback": true])
        XCTAssertEqual(obligations("qa"), ["result": true, "qa_report": true])
        for id in ["verify", "clean", "harden"] {
            XCTAssertEqual(obligations(id), ["result": true, "test_output": true, "exit_code": false], id)
        }
    }

    func testWithoutAHardenCommandTheStageIsSkipped() {
        let graph = CleanCodeLoopBuilder.build(from: makeContract(harden: false))
        XCTAssertNil(graph.nodes["harden"])
        XCTAssertNil(graph.nodes["kill-survivors"])
        let afterClean = graph.edges.first { $0.from == "clean" && { if case .outputMatch(_, "pass") = $0.condition { return true }; return false }($0) }?.to
        XCTAssertEqual(afterClean, "review")
    }

    func testWithoutAHumanGateQAPassesStraightToDone() {
        let graph = CleanCodeLoopBuilder.build(from: makeContract(humanGate: false))
        XCTAssertNil(graph.nodes["human-gate"])
        let afterQA = graph.edges.first { $0.from == "qa" && { if case .outputMatch(_, "pass") = $0.condition { return true }; return false }($0) }?.to
        XCTAssertEqual(afterQA, "done")
    }

    func testTheHumanGateDeniesBackToTheCoder() {
        let graph = CleanCodeLoopBuilder.build(from: makeContract())
        let gate = graph.edges.first { $0.from == "human-gate" }
        guard case .humanApproval(_, let denied)? = gate?.condition else { return XCTFail("no human gate edge") }
        XCTAssertEqual(denied, "implement")
    }

    func testTheAgentsAreWhoTheContractNames() {
        let graph = CleanCodeLoopBuilder.build(from: makeContract())
        XCTAssertEqual(graph.nodes["specify"]?.agentID, "spec")
        XCTAssertEqual(graph.nodes["implement"]?.agentID, "builder")
        XCTAssertEqual(graph.nodes["tidy"]?.agentID, "builder")
        XCTAssertEqual(graph.nodes["kill-survivors"]?.agentID, "builder")
        XCTAssertEqual(graph.nodes["review"]?.agentID, "reviewer")
        XCTAssertEqual(graph.nodes["qa"]?.agentID, "tester")
    }

    func testTheSpecifierAndReviewerCannotEditAndTheCoderIsScoped() {
        let contract = makeContract()
        let graph = CleanCodeLoopBuilder.build(from: contract)
        for id in ["specify", "review"] {
            XCTAssertTrue(graph.nodes[id]?.toolScopeOverride?.denied.contains("Edit") == true, id)
            XCTAssertTrue(graph.nodes[id]?.toolScopeOverride?.denied.contains("Write") == true, id)
        }
        for id in ["implement", "tidy", "kill-survivors"] {
            XCTAssertEqual(graph.nodes[id]?.fileScope?.allowedPaths, contract.scope, id)
            XCTAssertEqual(graph.nodes[id]?.fileScope?.frozenPaths, contract.frozenInterfaces, id)
        }
        XCTAssertTrue(graph.nodes["qa"]?.toolScopeOverride?.allowed?.contains("Bash") == true, "QA drives the procedure from the command line")
    }

    func testLimitsAndTagAreCarried() {
        let graph = CleanCodeLoopBuilder.build(from: makeContract())
        XCTAssertEqual(graph.maxIterations, 6)
        XCTAssertEqual(graph.globalTimeout, 90 * 60)
        XCTAssertEqual(graph.metadata.tags, [CleanCodeLoopBuilder.tag])
    }

    // MARK: - Prompts

    func testEveryPromptSubstitutesItsPlaceholders() {
        let graph = CleanCodeLoopBuilder.build(from: makeContract())
        for (id, node) in graph.nodes where node.agentID != nil {
            let prompt = WorkflowStateTemplater.render(template: node.prompt, state: populatedState).rendered
            XCTAssertEqual(unsubstitutedSpans(in: prompt), [], "\(id) left placeholders")
        }
    }

    func testTheRepairPromptsCarryTheToolsOutputAndTheContract() {
        let contract = makeContract()
        let graph = CleanCodeLoopBuilder.build(from: contract)
        let state: [String: AnyCodable] = populatedState.merging(["test_output": .string("Services/Foo.swift:12 crap 40 (cc 9, coverage 0%)")]) { $1 }
        for id in ["tidy", "kill-survivors"] {
            let prompt = WorkflowStateTemplater.render(template: graph.nodes[id]!.prompt, state: state).rendered
            XCTAssertTrue(prompt.contains("Services/Foo.swift:12 crap 40"), id)
            XCTAssertTrue(prompt.contains(contract.cleanCommand), id)
            XCTAssertTrue(prompt.contains("Sources/Parser/PublicAPI.swift"), id)
        }
    }

    func testTheCoderSeesTheAcceptanceAndOnlyTheFeedbackThatExists() {
        let graph = CleanCodeLoopBuilder.build(from: makeContract())
        let fresh: [String: AnyCodable] = ["goal": .string("g"), "acceptance": .string("Given x"), "_cwd": .string("/tmp")]
        let prompt = WorkflowStateTemplater.render(template: graph.nodes["implement"]!.prompt, state: fresh).rendered
        XCTAssertTrue(prompt.contains("Given x"))
        XCTAssertFalse(prompt.contains("The reviewer sent this back"))
        XCTAssertFalse(prompt.contains("QA ran the procedure"))
        XCTAssertFalse(prompt.contains("The last VERIFY run FAILED"))
    }
}
