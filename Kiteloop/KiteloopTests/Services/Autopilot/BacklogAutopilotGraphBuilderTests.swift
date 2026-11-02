import XCTest
import KiteloopCore
@testable import Kiteloop

/// Covers `BacklogAutopilot.buildWorkflowGraph` — the worker/reviewer loop every
/// autopilot run is executed as.
///
/// The shape is what makes a run terminate correctly: worker hands off to the
/// reviewer, and the reviewer's three outgoing edges are tried in priority order
/// (pass → done, fail → back to worker, anything else → the follow-up ask). A
/// wrong priority or a missing endpoint either loops forever or blocks a passing
/// item.
///
/// The fallback is `reviewer-clarify`, not `blocked`, and the difference is the
/// point: an answer with no `passed` field is an unreadable verdict, not a
/// rejection, and dead-ending on one threw away a reviewed diff and its approval.
/// Only the follow-up ask may fall through to `blocked`.
@MainActor
final class BacklogAutopilotGraphBuilderTests: XCTestCase {

    private func makeGraph(maxIterations: Int = 3) -> WorkflowGraph {
        BacklogAutopilot.buildWorkflowGraph(
            workerAgentID: "engineer",
            reviewerAgentID: "reviewer",
            maxIterations: maxIterations
        )
    }

    // MARK: - Nodes

    /// No reviewer: the worker hands straight to `done`, with no reviewer
    /// node for any edge to reach.
    func testWithNoReviewerTheGraphIsWorkerToDone() {
        let graph = BacklogAutopilot.buildWorkflowGraph(
            workerAgentID: "engineer", reviewerAgentID: nil, maxIterations: 3)
        XCTAssertEqual(Set(graph.nodes.keys), ["worker", "done", "blocked"])
        XCTAssertEqual(graph.entryNode, "worker")
        XCTAssertEqual(graph.terminalNodes, ["done", "blocked"])
        XCTAssertEqual(graph.edges.map { "\($0.from)->\($0.to)" }, ["worker->done"])
        XCTAssertEqual(graph.edges.first?.condition, .always)
        XCTAssertEqual(graph.nodes["worker"]?.agentID, "engineer")
    }

    /// No reviewer: the worker's prompt carries the self-review step, and the
    /// scope paragraph names the gates, not a reviewer that is not there.
    func testWithNoReviewerTheWorkerPromptCarriesTheSelfReviewStep() throws {
        let graph = BacklogAutopilot.buildWorkflowGraph(
            workerAgentID: "engineer", reviewerAgentID: nil, maxIterations: 3)
        let prompt = try XCTUnwrap(graph.nodes["worker"]?.prompt)
        XCTAssertTrue(prompt.contains("## Self-review"))
        XCTAssertTrue(prompt.contains("`git diff`"))
        XCTAssertTrue(prompt.contains("Validation line"))
        XCTAssertTrue(prompt.contains("Out of Scope entry"))
        XCTAssertTrue(prompt.contains("the gates block on scope"))
        XCTAssertFalse(prompt.contains("the reviewer blocks on scope"))
    }

    /// With a reviewer, the worker's prompt is the one it always was.
    func testWithAReviewerTheWorkerPromptIsUnchanged() {
        let prompt = makeGraph().nodes["worker"]?.prompt
        XCTAssertEqual(prompt, BacklogAutopilot.workerNodePrompt)
        XCTAssertFalse(prompt?.contains("## Self-review") ?? true)
        XCTAssertTrue(prompt?.contains("the reviewer blocks on scope") ?? false)
    }

    /// With a reviewer set, the edges are the worker/reviewer loop, in order.
    func testWithAReviewerTheEdgesAreTheReviewLoop() {
        XCTAssertEqual(makeGraph().edges.map { "\($0.from)->\($0.to)@\($0.priority)" }, [
            "worker->reviewer@0",
            "reviewer->done@0", "reviewer->worker@1", "reviewer->reviewer-clarify@10",
            "reviewer-clarify->done@0", "reviewer-clarify->worker@1", "reviewer-clarify->blocked@10",
        ])
    }

    func testGraphHasWorkerReviewerAndTerminalNodes() {
        let graph = makeGraph()
        XCTAssertEqual(Set(graph.nodes.keys),
                       ["worker", "reviewer", "reviewer-clarify", "done", "blocked"])
        XCTAssertEqual(graph.entryNode, "worker")
        XCTAssertEqual(graph.terminalNodes, ["done", "blocked"])
    }

    /// The worker's turn budget is the one the project's runs derived, not a
    /// constant of the builder; the reviewer's stays its own.
    func testWorkerNodeCarriesTheDerivedTurnBudget() {
        let graph = BacklogAutopilot.buildWorkflowGraph(
            workerAgentID: "engineer", reviewerAgentID: "reviewer", maxIterations: 3,
            workerMaxTurns: 90)
        XCTAssertEqual(graph.nodes["worker"]?.maxTurns, 90)
        XCTAssertEqual(graph.nodes["reviewer"]?.maxTurns, 20)
    }

    func testWorkerNodeUsesWorkerAgentWithGenerousBudget() {
        let graph = makeGraph()
        let worker = graph.nodes["worker"]
        XCTAssertEqual(worker?.id, "worker")
        XCTAssertEqual(worker?.agentID, "engineer")
        XCTAssertNil(worker?.subGraphID)
        XCTAssertEqual(worker?.maxTurns, 50)
        // Since 0.4.5 every node's wall clock is the stall budget — the turn
        // counts, not the clocks, are what separate worker and reviewer.
        XCTAssertEqual(worker?.timeoutSeconds, RunTimeouts.defaultWorkerMinutes * 60)
        XCTAssertNil(worker?.outputSchema, "the worker answers in prose, not JSON")
    }

    /// The worker prompt is templated against the item's state before the run;
    /// losing a placeholder silently drops that section from the brief.
    /// The closing instruction says to commit, and what happens otherwise —
    /// four of eight runs on 2026-09-03 handed off uncommitted trees.
    func testWorkerPromptTellsTheWorkerToCommitBeforeHandingOff() throws {
        let graph = BacklogAutopilot.buildWorkflowGraph(workerAgentID: "w", reviewerAgentID: "r", maxIterations: 3)
        let prompt = try XCTUnwrap(graph.nodes["worker"]?.prompt)
        XCTAssertTrue(prompt.contains("Commit your work before you hand off"), prompt)
        XCTAssertTrue(prompt.contains("advisory finding"), prompt)
    }

    func testWorkerPromptCarriesItemStatePlaceholders() throws {
        let prompt = try XCTUnwrap(makeGraph().nodes["worker"]?.prompt)
        for placeholder in [
            "{{state.title}}",
            "{{state.acceptanceCriteria}}",
            "{{state.verifyCommands}}",
            "{{state.previousFeedback}}"
        ] {
            XCTAssertTrue(prompt.contains(placeholder), "worker prompt is missing \(placeholder)")
        }
    }

    func testReviewerNodeUsesReviewerAgentWithTighterBudget() {
        let graph = makeGraph()
        let reviewer = graph.nodes["reviewer"]
        XCTAssertEqual(reviewer?.id, "reviewer")
        XCTAssertEqual(reviewer?.agentID, "reviewer")
        XCTAssertEqual(reviewer?.maxTurns, 20)
        XCTAssertEqual(reviewer?.timeoutSeconds, RunTimeouts.defaultWorkerMinutes * 60)
    }

    /// The `passed` field is what the reviewer's outgoing edges match on, so it
    /// has to be a required part of the declared output schema.
    func testReviewerNodeDeclaresPassedAndReasonOutput() throws {
        let schema = try XCTUnwrap(makeGraph().nodes["reviewer"]?.outputSchema)
        XCTAssertEqual(Set(schema.fields.keys), ["passed", "reason", "findings"])
        XCTAssertEqual(schema.fields["passed"]?.type, "boolean")
        XCTAssertEqual(schema.fields["passed"]?.required, true)
        XCTAssertEqual(schema.fields["reason"]?.type, "string")
        XCTAssertEqual(schema.fields["reason"]?.required, true)
    }

    /// Findings are the reviewer's severity channel, and they are optional on
    /// purpose: a reviewer that answers with a bare `passed` routes exactly as it
    /// did before they existed. Making the field required would turn every such
    /// answer into an unreadable verdict.
    func testFindingsAreAnOptionalPartOfTheVerdict() throws {
        let schema = try XCTUnwrap(makeGraph().nodes["reviewer"]?.outputSchema)
        XCTAssertEqual(schema.fields[ReviewFindings.outputKey]?.type, "array")
        XCTAssertEqual(schema.fields[ReviewFindings.outputKey]?.required, false)
    }

    /// The reviewer has to be told which observations block and which do not,
    /// or the severity field is filled in by guesswork.
    func testReviewerPromptExplainsBothSeverities() throws {
        let prompt = try XCTUnwrap(makeGraph().nodes["reviewer"]?.prompt)
        let flowed = prompt.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        XCTAssertTrue(flowed.contains("\"blocking\""), "reviewer prompt never names the blocking severity")
        XCTAssertTrue(flowed.contains("\"advisory\""), "reviewer prompt never names the advisory severity")
        XCTAssertTrue(flowed.contains("optional"),
                      "the prompt must say findings may be omitted, or a bare verdict looks wrong")
    }

    /// A reviewer handed no diff has no evidence for a single one of its
    /// criteria, so the prompt forbids the one verdict it can never earn — a
    /// green verify on an unchanged tree is not a passing review. The pre-review
    /// evidence gate should mean it never sees an empty diff at all; this is what
    /// it must answer if it does.
    func testReviewerPromptRefusesToPassAnEmptyDiff() throws {
        // Matched against whitespace-collapsed prose. The prompt is a wrapped
        // multi-line literal, so "fail the review" straddles a line break and a
        // run of indentation — an exact substring test passes or fails on where
        // an unrelated edit happens to re-wrap the paragraph, which is what
        // broke this on 2026-08-10 while the instruction was still there.
        let prompt = try XCTUnwrap(makeGraph().nodes["reviewer"]?.prompt)
        let flowed = prompt.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        XCTAssertTrue(flowed.contains("empty diff"), "reviewer prompt says nothing about an empty diff")
        XCTAssertTrue(flowed.contains("fail the review"),
                      "reviewer prompt must tell it to fail, not just to mention the absence")
    }

    // MARK: - Rubric 2 (How, before Validation)

    /// The travel incident this guards against: a reviewer that checked
    /// Validation alone passed a diff that satisfied every acceptance
    /// criterion by a route the item's How had ruled out. Rubric 2 has to be
    /// asked, in its own words, before a single Validation line is read.
    func testReviewerPromptAsksRubric2BeforeValidation() throws {
        let prompt = try XCTUnwrap(makeGraph().nodes["reviewer"]?.prompt)
        let flowed = prompt.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        XCTAssertTrue(flowed.contains("by the means How names"),
                      "reviewer prompt never asks the rubric-2 question in its own words")
        XCTAssertTrue(flowed.contains("blocking regardless of how many"),
                      "reviewer prompt must say a \"no\" here outweighs the Validation boxes")
        let rubric2 = try XCTUnwrap(prompt.range(of: "Rubric 2"), prompt)
        let validation = try XCTUnwrap(prompt.range(of: "## Validation"), prompt)
        XCTAssertTrue(rubric2.lowerBound < validation.lowerBound,
                      "rubric 2 must be asked before a single Validation line is checked")
    }

    /// One run in ten on 2026-09-12 was blocked for an unrequested extraction
    /// — a hoisted constant, a helper, a refactor inside a tests-only item —
    /// and every retry that dropped it passed. The worker is told, in so many
    /// words, to make no other change.
    func testWorkerPromptForbidsAnyChangeTheItemDidNotAskFor() throws {
        let prompt = try XCTUnwrap(makeGraph().nodes["worker"]?.prompt)
        let flowed = prompt.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        XCTAssertTrue(flowed.contains("Make no other change."), prompt)
        XCTAssertTrue(flowed.contains("no extracted helper, no hoisted constant"), prompt)
        XCTAssertTrue(flowed.contains("is a new backlog item, not a line in this one"), prompt)
    }

    /// Before this, the reviewer never saw How or Out of Scope at all — it
    /// read only What and Validation (`RescueRunTests
    /// .testTheScopeConstraintNamesTheConflictedSurfaceForTheReviewer` covers
    /// the rescue path's own `what`, not this). Both have to reach the
    /// reviewer, and ahead of Validation, or rubric 2 has nothing to check
    /// the diff against.
    func testReviewerPromptCarriesHowAndOutOfScopeBeforeValidation() throws {
        let reviewer = try renderedPrompts(detail: BacklogItemDetail(
            id: "abc", title: "Do the thing", verifyCommands: [],
            acceptanceCriteria: ["It works"], outOfScope: ["Changing the transport"],
            what: "Do the thing.", approach: "Run the generator.", premise: [])
        ).reviewer

        XCTAssertTrue(reviewer.contains("## How\nRun the generator."), reviewer)
        XCTAssertTrue(reviewer.contains("## Out of Scope\n- Changing the transport"), reviewer)
        let how = try XCTUnwrap(reviewer.range(of: "## How"), reviewer)
        let outOfScope = try XCTUnwrap(reviewer.range(of: "## Out of Scope"), reviewer)
        let validation = try XCTUnwrap(reviewer.range(of: "## Validation"), reviewer)
        XCTAssertTrue(how.lowerBound < validation.lowerBound, "How must be read before Validation")
        XCTAssertTrue(outOfScope.lowerBound < validation.lowerBound,
                      "Out of Scope must be read before Validation")
    }

    /// No How, no Out of Scope: no heading, no placeholder — the same
    /// leniency the worker prompt already gives these sections.
    func testReviewerPromptOmitsHowAndOutOfScopeWhenAbsent() throws {
        let reviewer = try renderedPrompts(detail: nil).reviewer
        XCTAssertFalse(reviewer.contains("## How"), reviewer)
        XCTAssertFalse(reviewer.contains("## Out of Scope"), reviewer)
        XCTAssertFalse(reviewer.contains("{{state.approach}}"), reviewer)
        XCTAssertFalse(reviewer.contains("{{state.outOfScope}}"), reviewer)
    }

    // MARK: - Accumulated project knowledge

    /// What the repo has learned reaches the agents doing the work. It used to
    /// reach only the grooming loop, the Coordinator chat and the advisor, so a
    /// worker re-learned "the app-hosted suite kills the app" at run cost, one
    /// run at a time.
    private func renderedPrompts(background: CoordinatorKnowledge.Background?) throws -> (worker: String, reviewer: String) {
        let state = BacklogAutopilot.buildInitialState(
            item: BacklogItem(id: "abc", title: "Do the thing", verify: nil,
                              status: .ready, type: .local, size: .m),
            detail: nil,
            worktree: nil,
            background: background
        )
        let graph = makeGraph()
        func render(_ nodeID: String) throws -> String {
            WorkflowStateTemplater.render(template: try XCTUnwrap(graph.nodes[nodeID]?.prompt),
                                          state: state).rendered
        }
        return (try render("worker"), try render("reviewer"))
    }

    func testBothRunPromptsCarryTheAccumulatedKnowledge() throws {
        let text = "\(CoordinatorKnowledge.autoHeader)\n- the app-hosted suite kills the running app"
        let prompts = try renderedPrompts(background: .init(text: text, bullets: 1))
        for (role, prompt) in [("worker", prompts.worker), ("reviewer", prompts.reviewer)] {
            XCTAssertTrue(prompt.contains("- the app-hosted suite kills the running app"),
                          "the \(role) starts the run blind to what the repo has learned")
            XCTAssertTrue(prompt.contains("## Accumulated project knowledge"),
                          "the \(role)'s knowledge arrives unlabelled")
        }
    }

    /// A distilled override line (`RunKnowledgeDistiller.overrideLines`) is
    /// prose in the same file as every other learned bullet — it needs no
    /// prompt change of its own, only for the mechanism above to still carry
    /// it. This is the reviewer's half of the lesson: the class it keeps
    /// blocking on is exactly what the human keeps overriding.
    func testAnOverrideLineReachesTheReviewerPrompt() throws {
        let line = RunKnowledgeDistiller.overrideLines([
            .init(itemID: "task-1", findingClass: "blocking: md missing changelog", at: Date()),
            .init(itemID: "task-2", findingClass: "blocking: md missing changelog", at: Date()),
            .init(itemID: "task-3", findingClass: "blocking: md missing changelog", at: Date()),
            .init(itemID: "task-4", findingClass: "blocking: md missing changelog", at: Date()),
            .init(itemID: "task-5", findingClass: "blocking: md missing changelog", at: Date()),
        ], existingKnowledge: "").first
        let text = "\(CoordinatorKnowledge.autoHeader)\n- \(try XCTUnwrap(line))"

        let prompts = try renderedPrompts(background: .init(text: text, bullets: 1))

        XCTAssertTrue(prompts.reviewer.contains("blocking: md missing changelog"),
                      "the reviewer must read which class it keeps being overridden on")
        XCTAssertTrue(prompts.reviewer.contains("5 of 5"))
    }

    /// Nil is the missing-or-empty file, and it must cost nothing: no header, no
    /// heading with nothing under it, no tokens.
    func testNeitherPromptCarriesAHeaderWithoutKnowledge() throws {
        let prompts = try renderedPrompts(background: nil)
        for (role, prompt) in [("worker", prompts.worker), ("reviewer", prompts.reviewer)] {
            XCTAssertFalse(prompt.contains("Accumulated project knowledge"),
                           "the \(role) got an empty knowledge section")
            XCTAssertFalse(prompt.contains("{{state.projectKnowledge}}"),
                           "the \(role)'s placeholder survived into the prompt")
        }
    }

    /// Background, not instructions. A distilled bullet is a lesson from another
    /// item; the item in hand is what governs, and nothing in the file may be
    /// read as licensing work the item ruled out.
    func testKnowledgeIsSubordinateToTheItemInBothPrompts() throws {
        let prompts = try renderedPrompts(background: .init(text: "- something", bullets: 1))
        let worker = prompts.worker.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        XCTAssertTrue(worker.contains("background, not instructions"),
                      "the worker must be told which of the two it is reading")
        XCTAssertTrue(worker.contains("the item wins"),
                      "the worker is not told what to do when a bullet and the item disagree")
        XCTAssertTrue(worker.contains("licenses work the item prohibits"),
                      "a bullet must not be readable as permission the item withheld")

        let reviewer = prompts.reviewer.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        XCTAssertTrue(reviewer.contains("background, not instructions"))
        XCTAssertTrue(reviewer.contains("neither a criterion the diff must meet"),
                      "the reviewer must not start rejecting work over a bullet")
    }

    /// The item's own sections come first: knowledge is context for the brief,
    /// and a brief read after its context is a brief read second.
    // MARK: - The item's premise

    /// The worker and reviewer prompts rendered for an item with the given
    /// detail — the premise block is state, rendered by `premiseBlock`, so it
    /// has to be asserted on the rendered prompt rather than the template.
    private func renderedPrompts(detail: BacklogItemDetail?, premiseReport: String? = nil) throws
        -> (worker: String, reviewer: String) {
        var state = BacklogAutopilot.buildInitialState(
            item: BacklogItem(id: "abc", title: "Do the thing", verify: nil,
                              status: .ready, type: .local, size: .m),
            detail: detail, worktree: nil, background: nil)
        if let premiseReport { state["premiseReport"] = .string(premiseReport) }
        let graph = makeGraph()
        func render(_ nodeID: String) throws -> String {
            WorkflowStateTemplater.render(template: try XCTUnwrap(graph.nodes[nodeID]?.prompt),
                                          state: state).rendered
        }
        return (try render("worker"), try render("reviewer"))
    }

    private func detail(premise: [String]) -> BacklogItemDetail {
        BacklogItemDetail(id: "abc", title: "Do the thing", verifyCommands: [],
                          acceptanceCriteria: ["It works"], outOfScope: [],
                          what: "The four qualifying functions change.",
                          approach: "Split each one.", premise: premise)
    }

    /// 2026-09-03: an item asserted four functions qualified, one did, and the
    /// first run built justifications for all four. The premise is put in
    /// front of the worker *before* the How — verify, then build — with the
    /// report shape the run reads back and the permission to stop.
    func testWorkerReadsThePremiseBeforeTheSuggestedApproach() throws {
        let prompts = try renderedPrompts(detail: detail(premise: [
            "`RetryCeiling.evaluate` is over CRAP 8", "`BacklogAIEditor.map` is over CRAP 8"]))
        let worker = prompts.worker
        let premise = try XCTUnwrap(worker.range(of: "## Premise — verify before building"), worker)
        let how = try XCTUnwrap(worker.range(of: "## Suggested Approach"), worker)
        let what = try XCTUnwrap(worker.range(of: "## What"), worker)
        XCTAssertTrue(what.lowerBound < premise.lowerBound, "the premise comes after the What")
        XCTAssertTrue(premise.lowerBound < how.lowerBound, "the premise must be read before the How")
        XCTAssertTrue(worker.contains("- `RetryCeiling.evaluate` is over CRAP 8"), worker)
        XCTAssertTrue(worker.contains("- `BacklogAIEditor.map` is over CRAP 8"), worker)
        let flat = worker.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        XCTAssertTrue(flat.contains("before changing anything"), flat)
        XCTAssertTrue(flat.contains("`held`, `refuted: <measurement>` or `unverifiable: <why>`"), flat)
        XCTAssertTrue(flat.contains("A refuted premise is a legitimate end to the run"), flat)
        XCTAssertTrue(flat.contains("Do not build on a claim you refuted"), flat)
        XCTAssertFalse(worker.contains("{{state.premise}}"), "the placeholder survived into the prompt")
    }

    /// An item that states no premise costs nothing: no heading, no
    /// instruction to verify claims that do not exist, no placeholder.
    func testWorkerPromptCarriesNoPremiseBlockWhenTheItemStatesNone() throws {
        for detail in [detail(premise: []), nil] {
            let worker = try renderedPrompts(detail: detail).worker
            XCTAssertFalse(worker.contains("Premise"), worker)
            XCTAssertFalse(worker.contains("{{state.premise}}"), worker)
            XCTAssertTrue(worker.contains("## Validation (acceptance criteria)"), worker)
        }
    }

    func testPremiseBlockIsNilForNoClaims() {
        XCTAssertNil(BacklogAutopilot.premiseBlock([]))
        XCTAssertNotNil(BacklogAutopilot.premiseBlock(["one claim"]))
    }

    /// The reviewer reads the worker's report beside the diff — rubric item 3
    /// is checked against the code either way — and is told what a `refuted`
    /// line is and what to do with a `held` one the code contradicts.
    func testReviewerReadsTheWorkersPremiseReportWhenThereIsOne() throws {
        let report = "- refuted: only `evaluate` is over 8; the other three read 4.1, 3.8, 2.0\n- held: the baseline lists all four"
        let reviewer = try renderedPrompts(detail: detail(premise: ["four are over 8"]),
                                           premiseReport: report).reviewer
        XCTAssertTrue(reviewer.contains("## Premise report"), reviewer)
        XCTAssertTrue(reviewer.contains(report), reviewer)
        let flat = reviewer.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        XCTAssertTrue(flat.contains("against the code, not against the worker's summary"), flat)
        XCTAssertTrue(flat.contains("is a scope failure"), flat)

        let without = try renderedPrompts(detail: detail(premise: ["four are over 8"])).reviewer
        XCTAssertFalse(without.contains("Premise report"), without)
        XCTAssertFalse(without.contains("{{state.premiseReport}}"), without)
    }

    func testKnowledgeSitsAfterTheItemsOwnSections() throws {
        let prompts = try renderedPrompts(background: .init(text: "- something", bullets: 1))
        let heading = try XCTUnwrap(prompts.worker.range(of: "## Accumulated project knowledge"))
        for section in ["## Validation (acceptance criteria)", "## Verify Commands"] {
            let own = try XCTUnwrap(prompts.worker.range(of: section))
            XCTAssertTrue(own.lowerBound < heading.lowerBound,
                          "\(section) must be read before the background knowledge")
        }
    }

    func testTerminalNodesRunNoAgent() {
        let graph = makeGraph()
        for id in ["done", "blocked"] {
            XCTAssertNil(graph.nodes[id]?.agentID, "'\(id)' should not spawn an agent")
            XCTAssertEqual(graph.nodes[id]?.prompt, "")
        }
    }

    // MARK: - Edges

    func testWorkerAlwaysHandsOffToReviewer() {
        let outgoing = makeGraph().edges.filter { $0.from == "worker" }
        XCTAssertEqual(outgoing.count, 1)
        XCTAssertEqual(outgoing.first?.to, "reviewer")
        XCTAssertEqual(outgoing.first?.condition, .always)
    }

    func testReviewerEdgesResolveInPriorityOrder() {
        let ordered = makeGraph().edges
            .filter { $0.from == "reviewer" }
            .sorted { $0.priority < $1.priority }
        XCTAssertEqual(ordered.map(\.to), ["done", "worker", "reviewer-clarify"])
        XCTAssertEqual(ordered.map(\.priority), [0, 1, 10])
        XCTAssertEqual(ordered[0].condition, .outputMatch(key: "passed", value: "true"))
        XCTAssertEqual(ordered[1].condition, .outputMatch(key: "passed", value: "false"))
        XCTAssertEqual(ordered[2].condition, .always,
                       "an unreadable verdict is re-asked, not blocked")
    }

    /// The reviewer must not be able to reach `blocked` in one step: a verdict
    /// nobody could parse has to be asked for again before the run dead-ends.
    func testReviewerCannotReachBlockedWithoutTheFollowUpAsk() {
        let toBlocked = makeGraph().edges.filter { $0.to == "blocked" }
        XCTAssertEqual(toBlocked.map(\.from), ["reviewer-clarify"])
    }

    func testClarifyEdgesRouteBothVerdictsBeforeBlocking() {
        let ordered = makeGraph().edges
            .filter { $0.from == "reviewer-clarify" }
            .sorted { $0.priority < $1.priority }
        XCTAssertEqual(ordered.map(\.to), ["done", "worker", "blocked"])
        XCTAssertEqual(ordered.map(\.priority), [0, 1, 10])
        XCTAssertEqual(ordered[0].condition, .outputMatch(key: "passed", value: "true"))
        XCTAssertEqual(ordered[1].condition, .outputMatch(key: "passed", value: "false"))
        XCTAssertEqual(ordered[2].condition, .always, "blocked is the last-resort fallback")
    }

    /// The follow-up ask runs the *reviewer*, asks for the same two fields, and
    /// gets a small budget — it is one question about a judgement that already
    /// exists, not a second review.
    func testClarifyNodeReAsksTheReviewerForTheSameVerdict() throws {
        let clarify = try XCTUnwrap(makeGraph().nodes["reviewer-clarify"])
        XCTAssertEqual(clarify.agentID, "reviewer")
        XCTAssertEqual(clarify.outputSchema, BacklogAutopilot.reviewerOutputSchema)
        XCTAssertLessThan(try XCTUnwrap(clarify.maxTurns), 20)
        XCTAssertTrue(clarify.prompt.contains("{{state.title}}"))
        XCTAssertTrue(clarify.prompt.contains("passed"))
        // Symmetric on purpose — the ask must not make approval the easy answer.
        XCTAssertTrue(clarify.prompt.contains("true"))
        XCTAssertTrue(clarify.prompt.contains("false"))
        XCTAssertTrue(clarify.prompt.contains("do not change your mind"),
                      "the follow-up asks for the decision already made, not a new one")
    }

    func testTerminalNodesHaveNoOutgoingEdges() {
        let graph = makeGraph()
        for edge in graph.edges {
            XCTAssertFalse(graph.terminalNodes.contains(edge.from),
                           "terminal '\(edge.from)' has an outgoing edge to '\(edge.to)'")
        }
    }

    func testEveryEdgeEndpointResolvesToANode() {
        let graph = makeGraph()
        // 7 since the reviewer-clarify node landed: worker→reviewer, the
        // reviewer's three, and the same three again from clarify.
        XCTAssertEqual(graph.edges.count, 7)
        for edge in graph.edges {
            XCTAssertNotNil(graph.nodes[edge.from], "edge source '\(edge.from)' missing")
            XCTAssertNotNil(graph.nodes[edge.to], "edge target '\(edge.to)' missing")
        }
    }

    func testEveryNonEntryNodeIsReachable() {
        let graph = makeGraph()
        var reachable: Set<String> = [graph.entryNode]
        var frontier = [graph.entryNode]
        while let current = frontier.popLast() {
            for edge in graph.edges where edge.from == current && !reachable.contains(edge.to) {
                reachable.insert(edge.to)
                frontier.append(edge.to)
            }
        }
        XCTAssertEqual(reachable, Set(graph.nodes.keys))
    }

    // MARK: - Graph settings

    func testMaxIterationsIsCarriedThrough() {
        XCTAssertEqual(makeGraph(maxIterations: 5).maxIterations, 5)
        XCTAssertEqual(makeGraph(maxIterations: 1).maxIterations, 1)
        XCTAssertNil(makeGraph().globalTimeout)
    }

    func testEachBuildGetsAUniquePrefixedID() {
        let first = makeGraph()
        let second = makeGraph()
        XCTAssertTrue(first.id.hasPrefix("backlog-autopilot-"))
        XCTAssertNotEqual(first.id, second.id, "each run needs its own graph id")
        XCTAssertEqual(first.name, "Backlog Item Execution")
        XCTAssertEqual(first.version, 1)
    }

    func testGraphSurvivesRoundTripWithLookupsIntact() throws {
        let graph = makeGraph(maxIterations: 4)
        let decoded = try JSONDecoder().decode(WorkflowGraph.self, from: JSONEncoder().encode(graph))
        XCTAssertEqual(Set(decoded.nodes.keys), Set(graph.nodes.keys))
        XCTAssertEqual(decoded.entryNode, "worker")
        XCTAssertEqual(decoded.terminalNodes, ["done", "blocked"])
        XCTAssertEqual(decoded.maxIterations, 4)
        XCTAssertEqual(decoded.nodes["reviewer"]?.outputSchema?.fields["passed"]?.required, true)

        let ordered = decoded.edges
            .filter { $0.from == "reviewer" }
            .sorted { $0.priority < $1.priority }
        // The reviewer no longer falls through to `blocked` directly: an
        // unreadable verdict is asked about once first, so the last resort from
        // here is the clarify node and `blocked` sits behind it.
        XCTAssertEqual(ordered.map(\.to), ["done", "worker", "reviewer-clarify"])

        let afterClarify = decoded.edges
            .filter { $0.from == "reviewer-clarify" }
            .sorted { $0.priority < $1.priority }
        XCTAssertEqual(afterClarify.map(\.to), ["done", "worker", "blocked"],
                       "a re-asked verdict must still be able to reach every outcome")
    }

    // MARK: - A rejection goes back to the worker

    /// The graph is the worker/reviewer loop and the clarify ask, node for node:
    /// a rejection has no exchange to pass through on its way back.
    func testTheGraphIsTheWorkerReviewerLoopAndNothingElse() {
        let graph = makeGraph()
        XCTAssertEqual(Set(graph.nodes.keys),
                       ["worker", "reviewer", "reviewer-clarify", "done", "blocked"])
        XCTAssertEqual(graph.edges.count, 7)
        for edge in graph.edges {
            if case .allOf(let conditions) = edge.condition {
                XCTFail("the graph gained a compound condition: \(conditions)")
            }
        }
    }

    /// A rejecting verdict routes straight back to the worker, on the verdict
    /// alone — nothing else has to be in the run's state for it to be taken.
    func testARejectionGoesStraightBackToTheWorker() throws {
        let back = try XCTUnwrap(makeGraph().edges.first { $0.from == "reviewer" && $0.to == "worker" })
        XCTAssertEqual(back.condition, .outputMatch(key: "passed", value: "false"))
        XCTAssertEqual(back.priority, 1)
    }

    // MARK: - What each node is to the run

    /// Which agent is behind the current node — what the stall watchdog reads to
    /// tell working from hung, and what the cost cap stops.
    func testOnlyTheWorkerNodeCountsAsTheWorker() {
        XCTAssertTrue(BacklogAutopilot.isWorkerNode("worker"))
        for node in ["reviewer", "reviewer-clarify", "done", "blocked"] {
            XCTAssertFalse(BacklogAutopilot.isWorkerNode(node), "\(node) is not the worker's")
        }
    }

    /// The node that reads a diff answers to the pre-review evidence gate, and
    /// neither of the two that don't: the follow-up ask is a question about a
    /// verdict that already exists, and the worker is what produces the diff.
    func testTheReviewOfADiffAnswersToTheEvidenceGate() {
        XCTAssertTrue(BacklogAutopilot.isGatedReviewNode("reviewer"))
        XCTAssertFalse(BacklogAutopilot.nodeHasStarted("reviewer", reviewGateOpen: false),
                       "reviewer was announced before the gate answered")
        XCTAssertTrue(BacklogAutopilot.nodeHasStarted("reviewer", reviewGateOpen: true))
        for node in ["worker", "reviewer-clarify"] {
            XCTAssertFalse(BacklogAutopilot.isGatedReviewNode(node))
            XCTAssertTrue(BacklogAutopilot.nodeHasStarted(node, reviewGateOpen: false))
        }
    }

    // MARK: - Where the reviewer reads the branch

    /// The reviewer node's prompt rendered against a run in `worktree` — the
    /// checkout path is state, so it can only be asserted on the built prompt
    /// rather than on the template.
    private func renderedReviewerPrompt(worktree: URL?) throws -> String {
        let state = BacklogAutopilot.buildInitialState(
            item: BacklogItem(id: "abc", title: "Do the thing", verify: nil,
                              status: .ready, type: .local, size: .m),
            detail: nil, worktree: worktree)
        return WorkflowStateTemplater.render(
            template: try XCTUnwrap(makeGraph().nodes["reviewer"]?.prompt), state: state).rendered
    }

    /// An isolated run's reviewer is started in the item's worktree
    /// (`WorktreeSession.begin`), but nothing in the prompt used to say so — a
    /// reviewer with a shell could check the branch out somewhere of its own
    /// and judge a tree the work never happened in.
    func testTheReviewerPromptNamesTheCheckoutTheBranchIsOpenAt() throws {
        let prompt = try renderedReviewerPrompt(worktree: URL(fileURLWithPath: "/tmp/wt/some-item"))

        XCTAssertTrue(prompt.contains("/tmp/wt/some-item"),
                      "the reviewer is not told where the branch is checked out:\n\(prompt)")
        XCTAssertFalse(prompt.contains("{{state.worktreePath}}"),
                       "the checkout placeholder survived into the prompt")
    }

    /// A live-tree run has no separate checkout to name, so the section
    /// collapses rather than rendering a heading over nothing.
    func testWithNoWorktreeTheReviewerPromptCarriesNoCheckoutSection() throws {
        let prompt = try renderedReviewerPrompt(worktree: nil)

        XCTAssertFalse(prompt.contains("Where the work is"),
                       "a live-tree run got a checkout section with no checkout")
        XCTAssertFalse(prompt.contains("{{state.worktreePath}}"))
    }

    // MARK: - The verdict schema

    /// The schema's fields are spelled `OutputSchema.SchemaField(…)` rather
    /// than `.init(…)` so lizard stops reading the dict literal as a function
    /// declaration running to the end of `reviewerNodePrompt`. That is a
    /// spelling change and nothing else: this reads the value back, so a future
    /// edit to it cannot pass as one.
    func testTheReviewerSchemaDeclaresTheVerdictFieldsItAlwaysHas() throws {
        let fields = BacklogAutopilot.reviewerOutputSchema.fields
        XCTAssertEqual(Set(fields.keys), ["passed", "reason", ReviewFindings.outputKey])

        let passed = try XCTUnwrap(fields["passed"])
        XCTAssertEqual(passed.type, "boolean")
        XCTAssertTrue(passed.required)
        XCTAssertEqual(passed.description, "Whether all AC and verify commands pass")

        let reason = try XCTUnwrap(fields["reason"])
        XCTAssertEqual(reason.type, "string")
        XCTAssertTrue(reason.required)
        XCTAssertEqual(reason.description, "Brief explanation of the verdict")

        let findings = try XCTUnwrap(fields[ReviewFindings.outputKey])
        XCTAssertEqual(findings.type, "array")
        XCTAssertFalse(findings.required, "a bare `passed` verdict must still route")
        XCTAssertEqual(findings.description,
                       #"Findings, each {severity: "blocking"|"advisory", text, file}"#)
    }
}
