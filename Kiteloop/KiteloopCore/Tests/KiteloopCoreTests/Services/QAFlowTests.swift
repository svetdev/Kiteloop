import XCTest
@testable import KiteloopCore

/// The QA flow for a UI feature: `flow:qa` on the item line, the project's
/// `kiteloop-qa.json`, the Definition-of-Ready clause that refuses a `flow:qa`
/// item in a project without one, and the stages added around a run's graph —
/// specify before the worker, the project's clean and harden commands after it,
/// and QA before `done`, each sending a failure back to the worker.
final class QAFlowTests: XCTestCase {

    // MARK: - The line

    func testALineCarryingFlowQAParsesWithTheFlowSet() {
        let item = BacklogParser.parseItemLine(
            "- [ ] today-tomorrow | Today shows tomorrow | size:S | lane:now | flow:qa | ready", verifyDefault: nil)
        XCTAssertEqual(item?.flow, .qa)
        XCTAssertEqual(item?.lane, .now)
    }

    func testALineWithNoFlowIsStandard() {
        XCTAssertEqual(BacklogParser.parseItemLine("- [ ] a | A | size:S | ready", verifyDefault: nil)?.flow, .standard)
    }

    func testAnUnreadableFlowIsReportedAndLeftStandard() {
        let parsed = BacklogParser.parseItemLineWithUnrecognisedFields(
            "- [ ] a | A | flow:e2e | ready", verifyDefault: nil)
        XCTAssertEqual(parsed?.item.flow, .standard)
        XCTAssertEqual(parsed?.unreadable, [BacklogParser.UnreadableValue(field: "flow:e2e", kind: .flow)])
    }

    /// Only `qa` is written, beside the lane; a standard item's line is unchanged.
    func testFlowQAIsWrittenBackAndStandardIsNot() {
        var item = BacklogItem(id: "a", title: "A", status: .ready, type: .local, size: .s, lane: .now)
        XCTAssertFalse(BacklogSerializer.serializeItem(item).contains("flow:"))
        item.flow = .qa
        let line = BacklogSerializer.serializeItem(item)
        XCTAssertTrue(line.contains("| lane:now | flow:qa"), line)
        XCTAssertEqual(BacklogParser.parseItemLine(line, verifyDefault: nil)?.flow, .qa)
    }

    // MARK: - The profile

    private func writeProfile(_ json: String) throws -> URL {
        let root = try makeTemporaryDirectory(prefix: "qa-profile")
        try Data(json.utf8).write(to: root.appending(path: QAProfile.fileName))
        return root
    }

    private let travelLike = """
    {"run": "./scripts/qa/run-flow.sh {spec}", "smoke": "./scripts/qa/smoke.sh",
     "spec": "apps/web/e2e/stack/qa/{id}.spec.ts", "storyboard": "apps/web/e2e/stack/storyboards/{id}.md",
     "clean": "./scripts/quality-preflight.sh"}
    """

    func testAProfileAtTheRootLoadsAndNamesTheItemsFiles() throws {
        let profile = try XCTUnwrap(QAProfile.load(projectRoot: writeProfile(travelLike)).profile)
        XCTAssertEqual(profile.specPath(itemID: "today-tomorrow"), "apps/web/e2e/stack/qa/today-tomorrow.spec.ts")
        XCTAssertEqual(profile.storyboardPath(itemID: "today-tomorrow"), "apps/web/e2e/stack/storyboards/today-tomorrow.md")
        XCTAssertEqual(profile.runCommand(itemID: "today-tomorrow"),
                       "./scripts/qa/run-flow.sh apps/web/e2e/stack/qa/today-tomorrow.spec.ts")
        XCTAssertNil(profile.harden)
    }

    func testNoProfileIsAbsent() throws {
        XCTAssertEqual(QAProfile.load(projectRoot: try makeTemporaryDirectory(prefix: "qa-profile-none")), .absent)
    }

    func testAProfileThatCannotDriveARunIsUnreadableAndSaysWhy() throws {
        let noPlaceholder = travelLike.replacingOccurrences(of: " {spec}", with: "")
        guard case .unreadable(let reason) = QAProfile.load(projectRoot: try writeProfile(noPlaceholder)) else {
            return XCTFail("a run command naming no flow must not load")
        }
        XCTAssertTrue(reason.contains("{spec}"), reason)

        guard case .unreadable = QAProfile.load(projectRoot: try writeProfile("{ not json")) else {
            return XCTFail("a malformed file must not load")
        }
    }

    // MARK: - Definition-of-Ready

    private func qaItem() -> BacklogItem {
        var item = BacklogItem(id: "today-tomorrow", title: "Today shows tomorrow", verify: "npm test",
                               status: .ready, type: .local, size: .s)
        item.flow = .qa
        return item
    }

    private let detail = BacklogItemDetail(id: "today-tomorrow", title: "Today shows tomorrow", size: "S",
                                           verifyCommands: [.init(name: "verify", cmd: "npm test", expect: nil)],
                                           acceptanceCriteria: ["Tomorrow's rides are listed"], outOfScope: [],
                                           what: "Show tomorrow.", approach: "Extend the range.")

    func testAQAItemInAProjectWithNoProfileIsRefusedWithTheFileToAdd() {
        let verdict = DefinitionOfReady.evaluate(item: qaItem(), detail: detail, qaProfile: .absent)
        XCTAssertEqual(verdict.unmet, [.qaProfile])
        XCTAssertTrue(verdict.reasons.joined().contains(QAProfile.fileName))
    }

    func testAQAItemWithAProfileIsReady() throws {
        let load = QAProfile.load(projectRoot: try writeProfile(travelLike))
        XCTAssertTrue(DefinitionOfReady.evaluate(item: qaItem(), detail: detail, qaProfile: load).isReady)
    }

    /// A standard item is never judged on QA, and nobody asking leaves the clause silent.
    func testTheClauseOnlyJudgesQAItemsAndOnlyWhenAsked() {
        var standard = qaItem()
        standard.flow = .standard
        XCTAssertTrue(DefinitionOfReady.evaluate(item: standard, detail: detail, qaProfile: .absent).isReady)
        XCTAssertTrue(DefinitionOfReady.evaluate(item: qaItem(), detail: detail).isReady)
    }

    // MARK: - The stages

    /// The autopilot's graph in miniature: worker → reviewer → done, rejection back.
    private func ordinaryGraph() -> WorkflowGraph {
        WorkflowGraph(
            id: "run", name: "run", version: 1,
            nodes: ["worker": WorkflowNode(id: "worker", agentID: "coder", prompt: "Build it."),
                    "reviewer": WorkflowNode(id: "reviewer", agentID: "rev", prompt: "Review it."),
                    "done": WorkflowNode(id: "done", prompt: ""),
                    "blocked": WorkflowNode(id: "blocked", prompt: "")],
            edges: [WorkflowEdge(from: "worker", to: "reviewer", condition: .always),
                    WorkflowEdge(from: "reviewer", to: "done", condition: .outputMatch(key: "passed", value: "true")),
                    WorkflowEdge(from: "reviewer", to: "worker", condition: .outputMatch(key: "passed", value: "false"), priority: 1)],
            entryNode: "worker", terminalNodes: ["done", "blocked"],
            metadata: .empty, globalTimeout: 3600, maxIterations: 3)
    }

    private func profile(clean: String? = "./clean.sh", harden: String? = "./harden.sh") -> QAProfile {
        QAProfile(run: "./run.sh {spec}", smoke: "./smoke.sh", spec: "e2e/{id}.spec.ts",
                  storyboard: "e2e/boards/{id}.md", clean: clean, harden: harden, guide: "Use the Story helper.")
    }

    private func targets(_ graph: WorkflowGraph, from node: String) -> [String: EdgeCondition] {
        Dictionary(uniqueKeysWithValues: graph.edges.filter { $0.from == node }.map { ($0.to, $0.condition) })
    }

    private let pass = EdgeCondition.outputMatch(key: "result", value: "pass")
    private let fail = EdgeCondition.outputMatch(key: "result", value: "fail")
    private let qaPass = EdgeCondition.outputMatch(key: "qa_result", value: "pass")
    private let qaFail = EdgeCondition.outputMatch(key: "qa_result", value: "fail")

    func testTheFlowStartsAtTheSpecifierAndRunsEveryStageInOrder() {
        let graph = QAFlowStages.apply(to: ordinaryGraph(), profile: profile(), itemID: "t", agentID: "coder")

        XCTAssertEqual(graph.entryNode, "specify")
        XCTAssertEqual(targets(graph, from: "specify"), ["worker": .always])
        XCTAssertEqual(targets(graph, from: "worker"), ["clean": .always])
        XCTAssertEqual(targets(graph, from: "clean"), ["harden": pass, "worker": fail])
        XCTAssertEqual(targets(graph, from: "harden"), ["reviewer": pass, "worker": fail])
        XCTAssertEqual(targets(graph, from: "reviewer")["qa"], .outputMatch(key: "passed", value: "true"))
        XCTAssertNil(targets(graph, from: "reviewer")["done"], "a passed review reaches QA, not done")
        XCTAssertEqual(targets(graph, from: "reviewer")["worker"], .outputMatch(key: "passed", value: "false"))
        XCTAssertEqual(targets(graph, from: "qa"), ["done": qaPass, "worker": qaFail, "blocked": .always])
        XCTAssertEqual(graph.terminalNodes, ["done", "blocked"])
    }

    /// QA's verdict is its own: the checks leave `result: pass` in the run's
    /// state, and a condition falls back to state, so a QA answer with no
    /// verdict reached done on the harden stage's pass. Now it reaches neither
    /// done nor the worker — the catch-all, tried last, stops the run.
    func testAQAAnswerWithoutAVerdictCannotPassOnAnotherStagesResult() throws {
        let graph = QAFlowStages.apply(to: ordinaryGraph(), profile: profile(), itemID: "t", agentID: "coder")
        let fromQA = graph.edges.filter { $0.from == "qa" }
        XCTAssertFalse(fromQA.contains { $0.condition == pass || $0.condition == fail },
                       "QA must not route on the key the checks write")
        let blocked = try XCTUnwrap(fromQA.first { $0.to == "blocked" })
        XCTAssertEqual(blocked.priority, fromQA.map(\.priority).max(), "the catch-all is tried last")
        XCTAssertEqual(graph.nodes["qa"]?.outputSchema?.fields.keys.sorted(), ["qa_report", "qa_result", "storyboard"])
    }

    func testTheChecksAreShellStagesRunningTheProfilesCommands() {
        let graph = QAFlowStages.apply(to: ordinaryGraph(), profile: profile(), itemID: "t", agentID: "coder")
        XCTAssertEqual(graph.nodes["clean"]?.shellCommand, "./clean.sh")
        XCTAssertEqual(graph.nodes["harden"]?.shellCommand, "./harden.sh")
        XCTAssertNil(graph.nodes["qa"]?.shellCommand)
        XCTAssertEqual(graph.nodes["qa"]?.agentID, "coder")
    }

    /// A profile with no clean or harden command adds no stage for it.
    func testAProfileWithoutChecksHandsTheWorkerStraightToTheReviewer() {
        let graph = QAFlowStages.apply(to: ordinaryGraph(), profile: profile(clean: nil, harden: " "),
                                       itemID: "t", agentID: "coder")
        XCTAssertNil(graph.nodes["clean"])
        XCTAssertNil(graph.nodes["harden"])
        XCTAssertEqual(targets(graph, from: "worker"), ["reviewer": .always])
    }

    /// With no reviewer the worker's handoff reached done; it now reaches QA.
    func testAGraphWithoutAReviewerReachesQABeforeDone() {
        var noReviewer = ordinaryGraph()
        noReviewer.nodes["reviewer"] = nil
        noReviewer.edges = [WorkflowEdge(from: "worker", to: "done", condition: .always)]
        let graph = QAFlowStages.apply(to: noReviewer, profile: profile(clean: nil, harden: nil),
                                       itemID: "t", agentID: "coder")
        XCTAssertEqual(targets(graph, from: "worker"), ["qa": .always])
        XCTAssertEqual(targets(graph, from: "qa"), ["done": qaPass, "worker": qaFail, "blocked": .always])
    }

    /// The worker keeps its own prompt and learns where the flow goes; QA is
    /// told what to run, where the screenshots land, and that a red run fails
    /// however its screenshots look.
    func testThePromptsNameTheItemsFlowAndStoryboard() {
        let graph = QAFlowStages.apply(to: ordinaryGraph(), profile: profile(), itemID: "today", agentID: "coder")
        let worker = graph.nodes["worker"]?.prompt ?? ""
        XCTAssertTrue(worker.hasPrefix("Build it."))
        XCTAssertTrue(worker.contains("e2e/today.spec.ts"))
        XCTAssertTrue(worker.contains("{{state.qa_procedure}}"))
        XCTAssertTrue(worker.contains("Use the Story helper."))
        let qa = graph.nodes["qa"]?.prompt ?? ""
        XCTAssertTrue(qa.contains("./run.sh e2e/today.spec.ts"))
        XCTAssertTrue(qa.contains("e2e/boards/today.md"))
        XCTAssertTrue(qa.contains("if it exits non-zero, qa_result is fail whatever the screenshots show"))
        XCTAssertTrue(qa.contains("End with one JSON object"))
        XCTAssertEqual(graph.nodes["specify"]?.outputSchema?.fields.keys.sorted(), ["acceptance", "qa_procedure"])
        // Prose around the answer reached nobody: the worker and QA were handed
        // the placeholder `{{state.qa_procedure}}` because no field was read.
        XCTAssertTrue(graph.nodes["specify"]?.prompt.contains("End with one JSON object") ?? false)
    }

    // MARK: - The note

    func testAFinishedQARunLeavesItsVerdictStoryboardAndReport() {
        let note = QAFlowStages.note(report: "1. Today lists tomorrow — shown — pass", storyboard: "e2e/boards/t.md", passed: true)
        XCTAssertEqual(note, "QA passed — storyboard: e2e/boards/t.md\n\n1. Today lists tomorrow — shown — pass")
        XCTAssertTrue(QAFlowStages.note(report: "2. missing", storyboard: nil, passed: false)?.hasPrefix("QA did not pass — storyboard: none") ?? false)
    }

    func testARunQANeverReachedLeavesNoNote() {
        XCTAssertNil(QAFlowStages.note(report: nil, storyboard: "x", passed: false))
        XCTAssertNil(QAFlowStages.note(report: "  ", storyboard: "x", passed: false))
        XCTAssertEqual(QAFlowStages.note(report: nil, storyboard: nil, passed: false, reachedQA: true)?.hasPrefix("QA gave no verdict"), true)
    }
}
