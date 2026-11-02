import XCTest
import KiteloopCore
@testable import Kiteloop

/// The two cases of `ReviewFindingsTests` that reach the app: a verdict-less
/// findings list judged by the autopilot's blocked-review reason, and the
/// severity split driven through the autopilot's real graph under the engine.
/// Everything else about findings is package code and is tested beside it.
final class ReviewFindingsAutopilotTests: XCTestCase {

    private func state(passed: String? = nil, reason: String? = nil, findings: String? = nil)
        -> [String: AnyCodable] {
        var state: [String: AnyCodable] = [:]
        if let passed { state["passed"] = .string(passed) }
        if let reason { state["reason"] = .string(reason) }
        if let findings { state[ReviewFindings.outputKey] = .string(findings) }
        return state
    }

    func testFindingsWithoutAVerdictLeaveTheClarifyPathAlone() {
        let input = state(reason: "see findings",
                          findings: #"[{"severity":"blocking","text":"AC 3 unimplemented"}]"#)
        XCTAssertEqual(ReviewFindings.route(input), input)
        XCTAssertEqual(BacklogAutopilot.blockedReviewReason(state: ReviewFindings.route(input)),
                       BacklogAutopilot.unreadableVerdictReason)
    }

    // MARK: - Through the real graph

    /// End to end over `BacklogAutopilot.buildWorkflowGraph`: the severity is
    /// what decides which node the run lands on, with the same edges as before.
    func testSeverityDecidesWhichNodeTheRunReaches() async throws {
        func nodeAfterReview(findings: String) async throws -> String? {
            let engine = WorkflowEngine()
            let graph = await BacklogAutopilot.buildWorkflowGraph(
                workerAgentID: "w", reviewerAgentID: "r", maxIterations: 3)
            await engine.register(graph: graph)
            let execID = try await engine.start(graphID: graph.id, initialState: [:])
            _ = try await engine.handleEvent(WorkflowEvent(
                executionID: execID, nodeID: "worker", agentID: "w", type: .nodeCompleted, output: [:]))
            _ = try await engine.handleEvent(WorkflowEvent(
                executionID: execID, nodeID: "reviewer", agentID: "r", type: .nodeCompleted,
                output: ReviewFindings.route([
                    "passed": .string("true"),
                    "reason": .string("done"),
                    ReviewFindings.outputKey: .string(findings),
                ])))
            return await engine.execution(id: execID)?.currentNode
        }

        let advisory = try await nodeAfterReview(findings: #"[{"severity":"advisory","text":"nit"}]"#)
        XCTAssertEqual(advisory, "done", "an advisory finding must not cost the run an iteration")

        let blocking = try await nodeAfterReview(findings: #"[{"severity":"blocking","text":"AC 3 unmet"}]"#)
        XCTAssertEqual(blocking, "worker", "a blocking finding sends the work back")
    }

    // MARK: - Surviving an approval, across rounds

    /// The notes come from the review that ended the run, not from the merged
    /// state a multi-round run finishes with — otherwise the first round's
    /// findings are filed against the approval that never made them.
    @MainActor
    func testAdvisoryNotesComeFromTheApprovingRoundOnly() {
        func step(_ nodeID: String, findings: String) -> ExecutionStep {
            ExecutionStep(nodeID: nodeID, agentID: "r", spanID: nil, startedAt: Date(),
                          completedAt: Date(),
                          output: [ReviewFindings.outputKey: .string(findings)])
        }
        let execution = WorkflowExecution(
            id: "e1", graphID: "g", currentNode: "done", status: .completed,
            // What the merged state would carry: the first round's findings,
            // never removed by the rounds after it.
            state: state(passed: "true",
                         findings: #"[{"severity":"advisory","text":"first round nit"}]"#),
            steps: [
                step("reviewer", findings: #"[{"severity":"advisory","text":"first round nit"}]"#),
                step("worker", findings: "[]"),
                step("reviewer", findings: #"[{"severity":"advisory","text":"second round nit"}]"#),
            ])
        let notes = ReviewFindings.advisoryNotes(
            in: BacklogAutopilot.lastReviewOutput(in: execution))
        XCTAssertEqual(notes, ["review advisory — second round nit"])
    }

    @MainActor
    func testExecutionThatNeverReviewedHasNoReviewOutput() {
        let execution = WorkflowExecution(
            id: "e2", graphID: "g", currentNode: "blocked", status: .completed,
            state: state(passed: "true"), steps: [])
        XCTAssertTrue(BacklogAutopilot.lastReviewOutput(in: execution).isEmpty)
        XCTAssertTrue(BacklogAutopilot.lastReviewOutput(in: nil).isEmpty)
    }

    // MARK: - Drift

    /// `knownItemPaths` reads the same backticked-path shape `GroundingCheck`
    /// does, out of the item's own text — What, How, and the title — so a
    /// drifted finding is judged against what the item actually names.
    func testKnownItemPathsReadsBacktickedPathsFromWhatAndHow() {
        let item = BacklogItem(id: "x", title: "Fix the thing", status: .ready, type: .local)
        let detail = BacklogItemDetail(
            id: "x", title: "Fix the thing", verifyCommands: [],
            acceptanceCriteria: [], outOfScope: [],
            what: "Update `Services/Foo.swift` to do the thing.",
            approach: "Also touch `Services/Bar.swift` while there.")
        XCTAssertEqual(BacklogAutopilot.knownItemPaths(item: item, detail: detail),
                       ["Services/Foo.swift", "Services/Bar.swift"])
    }

    /// The seam `BacklogAutopilot` installs on the orchestrator
    /// (`workflowOutputRefinement`) passes `knownPaths` and `changedFiles`
    /// straight through to `ReviewFindings.route` — the same drift marking a
    /// package-level test already covers, exercised through the app's own
    /// entry point rather than the package's.
    func testRefineNodeOutputCarriesDriftContextThroughToReviewFindings() throws {
        let routed = BacklogAutopilot.refineNodeOutput(
            nodeID: "reviewer",
            output: state(passed: "false", reason: "sending it back",
                          findings: #"[{"severity":"advisory","text":"in scope","file":"Services/Foo.swift"},"#
                                  + #"{"severity":"advisory","text":"out of scope","file":"Services/Bar.swift"}]"#),
            knownPaths: ["Services/Foo.swift"],
            changedFiles: ["Services/Foo.swift"])
        let drift = try XCTUnwrap(routed[ReviewFindings.driftKey]?.stringValue)
        XCTAssertEqual(drift, "drift: Services/Bar.swift — out of scope")
    }

    // MARK: - Drift findings survive the run, in the item's Notes

    /// Every rejecting round's drift lines reach the Notes — a review, the
    /// clarify round and a later review alike — and nothing a
    /// non-review node carried under the same key does. They are never routed
    /// to the worker, so this is the only place they outlive the run.
    @MainActor
    func testDriftFromEveryReviewRoundIsWrittenToTheItemsNotes() throws {
        let (autopilot, backlog, notesURL) = try driftFixture()
        let execution = WorkflowExecution(
            id: "e3", graphID: "g", currentNode: "blocked", status: .completed, state: [:],
            steps: [
                driftStep("reviewer", "drift: Services/A.swift — first round"),
                driftStep("worker", "drift: Services/W.swift — not a reviewer's"),
                driftStep(BacklogAutopilot.reviewerClarifyNodeID, "drift: Services/B.swift — clarified"),
                driftStep("reviewer",
                          "drift: Services/C.swift — second round\ndrift: Services/D.swift — also second round"),
            ])

        autopilot.recordDriftFindingsForTesting(execution: execution, item: driftItem, backlog: backlog)

        let notes = try String(contentsOf: notesURL, encoding: .utf8)
        for path in ["A", "B", "C", "D"] {
            XCTAssertTrue(notes.contains("drift: Services/\(path).swift"), "missing \(path): \(notes)")
        }
        XCTAssertFalse(notes.contains("Services/W.swift"), "a worker step is not a review: \(notes)")
        XCTAssertTrue(autopilot.log.contains {
            $0.message == "4 review findings flagged as scope drift for drift-item — recorded in the "
                        + "item's Notes, not sent to the worker as a fix"
        }, "\(autopilot.log.map(\.message))")
    }

    /// A run with no drift — which is every run whose reviewer stayed in
    /// scope, and every run with no execution at all — writes nothing and
    /// says nothing.
    @MainActor
    func testARunWithNoDriftWritesNothing() throws {
        let (autopilot, backlog, notesURL) = try driftFixture()
        let before = try String(contentsOf: notesURL, encoding: .utf8)
        let inScope = WorkflowExecution(
            id: "e4", graphID: "g", currentNode: "done", status: .completed, state: [:],
            steps: [ExecutionStep(nodeID: "reviewer", agentID: "r", spanID: nil, startedAt: Date(),
                                  completedAt: Date(), output: ["passed": .string("true")])])

        autopilot.recordDriftFindingsForTesting(execution: inScope, item: driftItem, backlog: backlog)
        autopilot.recordDriftFindingsForTesting(execution: nil, item: driftItem, backlog: backlog)

        XCTAssertEqual(try String(contentsOf: notesURL, encoding: .utf8), before)
        XCTAssertFalse(autopilot.log.contains { $0.message.contains("scope drift") })
    }

    private let driftItem = BacklogItem(id: "drift-item", title: "Drift item", status: .active, type: .local)

    private func driftStep(_ nodeID: String, _ drift: String) -> ExecutionStep {
        ExecutionStep(nodeID: nodeID, agentID: "r", spanID: nil, startedAt: Date(), completedAt: Date(),
                      output: [ReviewFindings.driftKey: .string(drift)])
    }

    /// A project holding `driftItem` with a detail file for its Notes, and an
    /// autopilot over it. The view model is returned so the caller holds it:
    /// the autopilot's reference is weak.
    @MainActor
    private func driftFixture() throws -> (BacklogAutopilot, BacklogViewModel, URL) {
        let root = try makeTemporaryDirectory(prefix: "review-drift-notes")
        try """
        # Demo Backlog

        ## Epic: Now

        - [ ] drift-item | Drift item | active → [detail](backlog/drift-item.md)
        """.write(to: root.appending(path: "BACKLOG.md"), atomically: true, encoding: .utf8)
        let notesURL = root.appending(path: "backlog/drift-item.md")
        try FileManager.default.createDirectory(at: notesURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try "# Drift item\n\nWhat: test item.\n".write(to: notesURL, atomically: true, encoding: .utf8)
        let backlog = BacklogViewModel(
            globalConfigStore: GlobalConfigStore(storageURL: root.appendingPathComponent("global-config.json")))
        backlog.loadForProject(repoPath: root.path(percentEncoded: false))
        let autopilot = BacklogAutopilot()
        autopilot.configure(orchestrator: Orchestrator(runtime: MockAgentRuntime()), backlogViewModel: backlog,
                            configURL: root.appendingPathComponent("autopilot-config.json"),
                            projectPath: root.path(percentEncoded: false))
        return (autopilot, backlog, notesURL)
    }
}
