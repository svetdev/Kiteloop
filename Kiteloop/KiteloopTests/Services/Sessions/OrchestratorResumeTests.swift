import XCTest
import KiteloopCore
@testable import Kiteloop

/// Coverage for `Orchestrator.attemptResume` — the Resume press behind the
/// interrupted-workflows prompt. The defect these guard against: every failure
/// path used to return silently while the row was removed anyway, so a resume
/// that did nothing looked exactly like one that worked.
@MainActor
final class OrchestratorResumeTests: XCTestCase {

    /// The orchestrator never spawns a process in these tests; resume goes
    /// straight to the workflow engine.
    private final class IdleRuntime: AgentRuntime, @unchecked Sendable {
        func startSession(agent: Agent, cwd: URL, strategy: ResumeStrategy) async throws -> AgentSession {
            AgentSession(id: "session", agentID: agent.id, startedAt: .now)
        }
        func send(_ message: String, attachments: [ChatAttachment], to session: AgentSession) -> AsyncStream<StreamEvent> {
            AsyncStream { $0.finish() }
        }
        func sendToolResult(toolCallID: String, content: String, to session: AgentSession) -> AsyncStream<StreamEvent> {
            AsyncStream { $0.finish() }
        }
        func sendMCPToolResult(requestID: String, result: String, to session: AgentSession) {}
        func interrupt(session: AgentSession) {}
        func stop(session: AgentSession) {}
    }

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = try makeTemporaryDirectory(prefix: "kiteloop-resume")
    }

    // MARK: - Fixtures

    /// A two-node graph, `node-0` → `done`, with `done` terminal.
    private func makeGraph() -> WorkflowGraph {
        WorkflowGraph(
            id: "graph-1",
            name: "Nightly Build",
            version: 1,
            nodes: [
                "node-0": WorkflowNode(id: "node-0", agentID: "agent-a", prompt: "Do work"),
                "done": WorkflowNode(id: "done", agentID: "agent-a", prompt: "Wrap up")
            ],
            edges: [WorkflowEdge(from: "node-0", to: "done", condition: .always)],
            entryNode: "node-0",
            terminalNodes: ["done"],
            metadata: .empty
        )
    }

    private func makeCheckpoint(executionID: String, currentNode: String) -> WorkflowCheckpoint {
        let graph = makeGraph()
        let execution = WorkflowExecution(
            id: executionID,
            graphID: graph.id,
            currentNode: currentNode,
            status: .running,
            state: [:]
        )
        return WorkflowCheckpoint(
            executionID: executionID,
            graphSnapshot: graph,
            executionSnapshot: execution,
            reason: .nodeTransition
        )
    }

    private func makeRow(
        executionID: String,
        currentNode: String,
        itemID: String? = nil,
        itemTitle: String? = nil
    ) -> IncompleteExecution {
        IncompleteExecution(
            id: executionID,
            graphID: "graph-1",
            graphName: "Nightly Build",
            currentNode: currentNode,
            status: .running,
            interruptedAt: Date(),
            traceID: "trace-1",
            state: [:],
            itemID: itemID,
            itemTitle: itemTitle,
            projectName: "kiteloop",
            completedStepCount: 0
        )
    }

    private func makeOrchestrator(withResumeService: Bool) -> Orchestrator {
        let orchestrator = Orchestrator(runtime: IdleRuntime())
        if withResumeService {
            orchestrator.configureResumeService(
                checkpointStore: WorkflowCheckpointStore(baseURL: tempDir),
                projectName: "kiteloop"
            )
        }
        return orchestrator
    }

    // MARK: - Failure paths

    /// No resume service configured: the press is reported and the row stays put.
    func testResumeWithoutServiceReportsAndKeepsRow() async throws {
        let orchestrator = makeOrchestrator(withResumeService: false)
        orchestrator.incompleteExecutions = [makeRow(executionID: "exec-1", currentNode: "node-0")]

        let report = await orchestrator.attemptResume(executionID: "exec-1")

        XCTAssertFalse(report.succeeded)
        XCTAssertTrue(report.message.contains("checkpointing isn't configured"),
                      "The report should name the missing service, got: \(report.message)")
        XCTAssertEqual(orchestrator.incompleteExecutions.map(\.id), ["exec-1"],
                       "A resume that did not happen must not remove the row")
        XCTAssertEqual(orchestrator.lastResumeReport, report)
    }

    /// No checkpoint on disk: the error from the service reaches the user
    /// instead of being swallowed by a `try?`, and the row stays.
    func testResumeWithoutCheckpointReportsAndKeepsRow() async throws {
        let orchestrator = makeOrchestrator(withResumeService: true)
        orchestrator.incompleteExecutions = [makeRow(executionID: "exec-1", currentNode: "node-0")]

        let report = await orchestrator.attemptResume(executionID: "exec-1")

        XCTAssertFalse(report.succeeded)
        XCTAssertTrue(report.message.contains("Nightly Build"),
                      "The report should name the workflow, got: \(report.message)")
        XCTAssertTrue(report.message.contains("no checkpoint"),
                      "The report should carry the service's reason, got: \(report.message)")
        XCTAssertEqual(orchestrator.incompleteExecutions.map(\.id), ["exec-1"])
    }

    /// Every autopilot run shares one graph, so a report that named the graph
    /// named nothing. The item is what tells the user which run this was.
    func testResumeReportNamesTheBacklogItemNotTheGraph() async throws {
        let orchestrator = makeOrchestrator(withResumeService: true)
        orchestrator.incompleteExecutions = [
            makeRow(
                executionID: "exec-1",
                currentNode: "node-0",
                itemID: "resume-prompt-unidentifiable",
                itemTitle: "Name the item in the resume prompt"
            )
        ]

        let report = await orchestrator.attemptResume(executionID: "exec-1")

        XCTAssertTrue(report.message.contains("Name the item in the resume prompt"),
                      "The report should name the item, got: \(report.message)")
        XCTAssertFalse(report.message.contains("Nightly Build"),
                       "The graph name is the same for every run and identifies nothing, got: \(report.message)")
    }

    /// A checkpoint parked on a terminal node cannot be continued; the refusal is
    /// reported and the row stays so the user can dismiss it.
    func testResumeAtTerminalNodeIsRefusedAndKeepsRow() async throws {
        let store = WorkflowCheckpointStore(baseURL: tempDir)
        try await store.write(makeCheckpoint(executionID: "exec-end", currentNode: "done"))

        let orchestrator = makeOrchestrator(withResumeService: true)
        orchestrator.incompleteExecutions = [makeRow(executionID: "exec-end", currentNode: "done")]

        let report = await orchestrator.attemptResume(executionID: "exec-end")

        XCTAssertFalse(report.succeeded)
        XCTAssertTrue(report.message.contains("final node"),
                      "The report should explain the node is terminal, got: \(report.message)")
        XCTAssertEqual(orchestrator.incompleteExecutions.map(\.id), ["exec-end"])

        let execution = await orchestrator.workflowEngine.execution(id: "exec-end")
        XCTAssertNil(execution, "A refused resume must not register an execution")
    }

    // MARK: - Success path

    /// A resume that took removes the row, reports success, and leaves a running
    /// execution in the engine.
    func testSuccessfulResumeRemovesRowAndRegistersExecution() async throws {
        let store = WorkflowCheckpointStore(baseURL: tempDir)
        try await store.write(makeCheckpoint(executionID: "exec-mid", currentNode: "node-0"))

        let orchestrator = makeOrchestrator(withResumeService: true)
        orchestrator.incompleteExecutions = [
            makeRow(executionID: "exec-mid", currentNode: "node-0"),
            makeRow(executionID: "other", currentNode: "node-0")
        ]

        let report = await orchestrator.attemptResume(executionID: "exec-mid")

        XCTAssertTrue(report.succeeded)
        XCTAssertTrue(report.message.contains("Nightly Build"), "got: \(report.message)")
        XCTAssertEqual(orchestrator.incompleteExecutions.map(\.id), ["other"],
                       "Only the resumed row should be removed")

        let execution = await orchestrator.workflowEngine.execution(id: "exec-mid")
        XCTAssertEqual(execution?.status, .running)
        XCTAssertEqual(execution?.currentNode, "node-0")
    }

    /// Dismissing a row clears a resume failure that was about it, so the prompt
    /// never explains a row that is no longer there.
    func testDismissClearsStaleResumeReport() async throws {
        let orchestrator = makeOrchestrator(withResumeService: true)
        orchestrator.incompleteExecutions = [makeRow(executionID: "exec-1", currentNode: "node-0")]

        _ = await orchestrator.attemptResume(executionID: "exec-1")
        XCTAssertNotNil(orchestrator.lastResumeReport)

        orchestrator.dismissWorkflow(executionID: "exec-1")
        // `dismissWorkflow` hops through a detached task, so wait for its effect.
        try await eventually("the dismissed row to leave incompleteExecutions") {
            await orchestrator.incompleteExecutions.isEmpty
        }

        XCTAssertNil(orchestrator.lastResumeReport,
                     "A dismissed row should not leave its failure message on screen")
    }

    /// No resume service configured: Dismiss used to empty the row silently
    /// while the checkpoints stayed on disk. It reports instead, and keeps it.
    func testDismissWithoutServiceReportsAndKeepsRow() async throws {
        let orchestrator = makeOrchestrator(withResumeService: false)
        orchestrator.incompleteExecutions = [makeRow(executionID: "exec-1", currentNode: "node-0")]

        let report = await orchestrator.attemptDismiss(executionID: "exec-1")

        XCTAssertFalse(report.succeeded)
        XCTAssertTrue(report.message.contains("checkpointing isn't configured"),
                      "The report should name the missing service, got: \(report.message)")
        XCTAssertEqual(orchestrator.incompleteExecutions.map(\.id), ["exec-1"],
                       "A dismiss that did not happen must not remove the row")
        XCTAssertEqual(orchestrator.lastResumeReport, report)
    }

    /// The same for Dismiss All, which cleared the whole list regardless.
    func testDismissAllWithoutServiceReportsAndKeepsRows() async throws {
        let orchestrator = makeOrchestrator(withResumeService: false)
        orchestrator.incompleteExecutions = [
            makeRow(executionID: "exec-1", currentNode: "node-0"),
            makeRow(executionID: "exec-2", currentNode: "node-0")
        ]

        let report = await orchestrator.attemptDismissAll()

        XCTAssertFalse(report.succeeded)
        XCTAssertTrue(report.message.contains("checkpointing isn't configured"),
                      "The report should name the missing service, got: \(report.message)")
        XCTAssertEqual(orchestrator.incompleteExecutions.map(\.id), ["exec-1", "exec-2"],
                       "A Dismiss All that did nothing must not empty the list")
        XCTAssertEqual(orchestrator.lastResumeReport, report)
    }

    /// A dismiss that lands still takes its own row, and only its own.
    func testDismissRemovesOnlyItsOwnRow() async throws {
        let orchestrator = makeOrchestrator(withResumeService: true)
        orchestrator.incompleteExecutions = [
            makeRow(executionID: "exec-1", currentNode: "node-0"),
            makeRow(executionID: "exec-2", currentNode: "node-0")
        ]

        let report = await orchestrator.attemptDismiss(executionID: "exec-1")

        XCTAssertTrue(report.succeeded)
        XCTAssertEqual(orchestrator.incompleteExecutions.map(\.id), ["exec-2"])
    }

    /// And a Dismiss All that lands still empties the list.
    func testDismissAllEmptiesTheListWhenItLands() async throws {
        let orchestrator = makeOrchestrator(withResumeService: true)
        orchestrator.incompleteExecutions = [
            makeRow(executionID: "exec-1", currentNode: "node-0"),
            makeRow(executionID: "exec-2", currentNode: "node-0")
        ]

        let report = await orchestrator.attemptDismissAll()

        XCTAssertTrue(report.succeeded)
        XCTAssertTrue(orchestrator.incompleteExecutions.isEmpty)
        XCTAssertNil(orchestrator.lastResumeReport)
    }
}
