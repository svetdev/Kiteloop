import XCTest
import KiteloopCore
@testable import Kiteloop

final class WorkflowResumeServiceTests: XCTestCase {

    private func makeTempCheckpointStore() throws -> (WorkflowCheckpointStore, URL) {
        let tmpDir = try makeTemporaryDirectory(prefix: "resume-test")
        return (WorkflowCheckpointStore(baseURL: tmpDir), tmpDir)
    }

    private func makeEventBridge() -> WorkflowEventBridge {
        let eventsURL = FileManager.default.temporaryDirectory.appending(path: "resume-events-\(UUID().uuidString)")
        let bus = EventBus(eventsURL: eventsURL)
        return WorkflowEventBridge(eventBus: bus)
    }

    /// A two-node graph (`node-0` → `done`, with `done` terminal) checkpointed at
    /// `currentNode`. Parked on `node-0` it is resumable; parked on `done` it has
    /// already run to the end of the graph.
    private func makeIncompleteCheckpoint(
        executionID: String,
        graphID: String = "test-graph",
        currentNode: String = "node-0",
        status: ExecutionStatus = .running,
        state: [String: AnyCodable] = ["key": .string("value")],
        steps: [ExecutionStep] = [],
        checkpointedAt: Date = Date()
    ) -> WorkflowCheckpoint {
        let graph = WorkflowGraph(
            id: graphID,
            name: "Test Workflow",
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
        let execution = WorkflowExecution(
            id: executionID,
            graphID: graphID,
            currentNode: currentNode,
            status: status,
            state: state,
            steps: steps
        )
        return WorkflowCheckpoint(
            executionID: executionID,
            graphSnapshot: graph,
            executionSnapshot: execution,
            checkpointedAt: checkpointedAt,
            reason: .nodeTransition
        )
    }

    func testScanFindsIncompleteExecutions() async throws {
        let (store, _) = try makeTempCheckpointStore()
        let checkpoint = makeIncompleteCheckpoint(executionID: "exec-1")
        try await store.write(checkpoint)

        let engine = WorkflowEngine(queueTimeout: 5.0)
        let bridge = makeEventBridge()
        let service = WorkflowResumeService(checkpointStore: store, engine: engine, eventBridge: bridge, projectName: "kiteloop")

        let incomplete = await service.scanForIncomplete()
        XCTAssertEqual(incomplete.count, 1)
        XCTAssertEqual(incomplete.first?.id, "exec-1")
        XCTAssertEqual(incomplete.first?.graphName, "Test Workflow")
        XCTAssertEqual(incomplete.first?.currentNode, "node-0")
        XCTAssertEqual(incomplete.first?.status, .running)

    }

    func testScanReturnsEmptyWhenNoIncomplete() async throws {
        let (store, _) = try makeTempCheckpointStore()

        let engine = WorkflowEngine(queueTimeout: 5.0)
        let bridge = makeEventBridge()
        let service = WorkflowResumeService(checkpointStore: store, engine: engine, eventBridge: bridge, projectName: "kiteloop")

        let incomplete = await service.scanForIncomplete()
        XCTAssertEqual(incomplete.count, 0)

    }

    /// Dismiss means the run is not being continued, and resume is the only
    /// reader a checkpoint has — so the files go, rather than surviving as a
    /// cancelled marker nobody will ever read.
    func testDismissDeletesTheCheckpoints() async throws {
        let (store, tmpDir) = try makeTempCheckpointStore()
        let checkpoint = makeIncompleteCheckpoint(executionID: "exec-2")
        try await store.write(checkpoint)

        let engine = WorkflowEngine(queueTimeout: 5.0)
        let bridge = makeEventBridge()
        let service = WorkflowResumeService(checkpointStore: store, engine: engine, eventBridge: bridge, projectName: "kiteloop")

        try await service.dismiss(executionID: "exec-2")

        let remaining = await service.scanForIncomplete()
        XCTAssertEqual(remaining.count, 0)

        let latest = try await store.latestCheckpoint(executionID: "exec-2")
        XCTAssertNil(latest, "A dismissed execution should leave nothing on disk")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: tmpDir.appending(path: "exec-2").path),
            "The execution directory itself should be gone"
        )

    }

    /// A delete the file system refuses has to come back as an error: the row
    /// is about to be cleared on the strength of it, and the checkpoints are
    /// still there for the next launch to find.
    func testDismissThrowsWhenTheCheckpointsCannotBeDeleted() async throws {
        let (store, tmpDir) = try makeTempCheckpointStore()
        try await store.write(makeIncompleteCheckpoint(executionID: "exec-sealed"))

        let engine = WorkflowEngine(queueTimeout: 5.0)
        let bridge = makeEventBridge()
        let service = WorkflowResumeService(checkpointStore: store, engine: engine, eventBridge: bridge, projectName: "kiteloop")

        // Seal the execution directory itself, so the checkpoints inside it
        // cannot be unlinked. Sealing only the base would not do: `removeItem`
        // empties the execution dir first — the checkpoints go — and only the
        // final rmdir of the dir itself is refused.
        let sealedPath = tmpDir.appending(path: "exec-sealed").path(percentEncoded: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: sealedPath)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sealedPath)
        }

        do {
            try await service.dismiss(executionID: "exec-sealed")
            XCTFail("A delete the file system refused must not return as if it worked")
        } catch {
            // Expected.
        }

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sealedPath)
        let survivor = try await store.latestCheckpoint(executionID: "exec-sealed")
        XCTAssertNotNil(survivor, "The checkpoints the delete could not remove are still on disk")
    }

    /// The prompt must name the run: which backlog item, in which project,
    /// stopped when, and whether it left any finished steps behind.
    func testScanCarriesItemProjectAndProgress() async throws {
        let (store, _) = try makeTempCheckpointStore()
        let interruptedAt = Date(timeIntervalSince1970: 1_770_000_000)
        try await store.write(makeIncompleteCheckpoint(
            executionID: "exec-item",
            state: [
                "itemID": .string("resume-prompt-unidentifiable"),
                "title": .string("Name the item in the resume prompt"),
            ],
            steps: [
                ExecutionStep(nodeID: "node-0", agentID: "agent-a", spanID: nil,
                              startedAt: interruptedAt, completedAt: interruptedAt),
                ExecutionStep(nodeID: "node-1", agentID: "agent-a", spanID: nil,
                              startedAt: interruptedAt, completedAt: nil),
            ],
            checkpointedAt: interruptedAt
        ))

        let engine = WorkflowEngine(queueTimeout: 5.0)
        let service = WorkflowResumeService(checkpointStore: store, engine: engine, eventBridge: makeEventBridge(), projectName: "kiteloop")

        let rows = await service.scanForIncomplete()
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.itemID, "resume-prompt-unidentifiable")
        XCTAssertEqual(row.itemTitle, "Name the item in the resume prompt")
        XCTAssertEqual(row.displayName, "Name the item in the resume prompt")
        XCTAssertEqual(row.projectName, "kiteloop")
        XCTAssertEqual(row.interruptedAt, interruptedAt)
        XCTAssertEqual(row.completedStepCount, 1, "Only the step that finished counts as work left behind")

    }

    /// A workflow with no backlog item behind it still has to be nameable.
    func testScanFallsBackToGraphNameWithoutAnItem() async throws {
        let (store, _) = try makeTempCheckpointStore()
        try await store.write(makeIncompleteCheckpoint(executionID: "exec-bare", state: [:]))

        let engine = WorkflowEngine(queueTimeout: 5.0)
        let service = WorkflowResumeService(checkpointStore: store, engine: engine, eventBridge: makeEventBridge(), projectName: "kiteloop")

        let rows = await service.scanForIncomplete()
        let row = try XCTUnwrap(rows.first)
        XCTAssertNil(row.itemID)
        XCTAssertEqual(row.displayName, "Test Workflow")

    }

    /// Pruning is only ever allowed to remove what the scan would not offer.
    func testPruneKeepsEveryExecutionTheScanOffers() async throws {
        let (store, _) = try makeTempCheckpointStore()
        let longAgo = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.write(makeIncompleteCheckpoint(executionID: "exec-live", currentNode: "node-0", checkpointedAt: longAgo))
        try await store.write(makeIncompleteCheckpoint(executionID: "exec-parked", currentNode: "done", checkpointedAt: longAgo))
        try await store.write(makeIncompleteCheckpoint(executionID: "exec-failed", status: .failed, checkpointedAt: longAgo))

        let engine = WorkflowEngine(queueTimeout: 5.0)
        let service = WorkflowResumeService(checkpointStore: store, engine: engine, eventBridge: makeEventBridge(), projectName: "kiteloop")

        let offeredBefore = await service.scanForIncomplete().map(\.id)
        XCTAssertEqual(offeredBefore, ["exec-live"])

        let pruned = await service.pruneSettledCheckpoints()
        XCTAssertEqual(pruned, 2, "The parked and failed executions should go")

        let offeredAfter = await service.scanForIncomplete().map(\.id)
        XCTAssertEqual(offeredAfter, offeredBefore, "Pruning must not remove an execution the prompt offers")
        let live = try await store.latestCheckpoint(executionID: "exec-live")
        XCTAssertNotNil(live)

    }

    func testResumeRegistersGraphAndCreatesExecution() async throws {
        let (store, _) = try makeTempCheckpointStore()
        let checkpoint = makeIncompleteCheckpoint(executionID: "exec-3", graphID: "resume-graph")
        try await store.write(checkpoint)

        let engine = WorkflowEngine(queueTimeout: 5.0)
        let bridge = makeEventBridge()
        let service = WorkflowResumeService(checkpointStore: store, engine: engine, eventBridge: bridge, projectName: "kiteloop")

        try await service.resume(executionID: "exec-3")

        // Engine should now have the execution
        let execution = await engine.execution(id: "exec-3")
        XCTAssertNotNil(execution)
        XCTAssertEqual(execution?.status, .running)
        XCTAssertEqual(execution?.currentNode, "node-0")
        XCTAssertEqual(execution?.graphID, "resume-graph")

        // Should have the resume preamble in state
        XCTAssertNotNil(execution?.state["_resumePreamble"])

        // Graph should be registered
        let graph = await engine.registeredGraph(id: "resume-graph")
        XCTAssertNotNil(graph)

    }

    /// An execution with no checkpoint on disk has nothing to continue from, and
    /// must say so rather than return as though it resumed.
    func testResumeThrowsWhenNoCheckpointExists() async throws {
        let (store, _) = try makeTempCheckpointStore()

        let engine = WorkflowEngine(queueTimeout: 5.0)
        let service = WorkflowResumeService(checkpointStore: store, engine: engine, eventBridge: makeEventBridge(), projectName: "kiteloop")

        do {
            try await service.resume(executionID: "never-checkpointed")
            XCTFail("Resume with no checkpoint should throw")
        } catch let error as WorkflowResumeError {
            XCTAssertEqual(error, .noCheckpoint(executionID: "never-checkpointed"))
        }

        let execution = await engine.execution(id: "never-checkpointed")
        XCTAssertNil(execution, "A refused resume must not register an execution")

    }

    /// A checkpoint parked on a terminal node (autopilot's `blocked`/`done`) has
    /// already run to the end of its graph — resuming it would "succeed" without
    /// continuing anything, so it is refused.
    func testResumeRefusesExecutionAtTerminalNode() async throws {
        let (store, _) = try makeTempCheckpointStore()
        try await store.write(makeIncompleteCheckpoint(executionID: "exec-terminal", currentNode: "done"))

        let engine = WorkflowEngine(queueTimeout: 5.0)
        let service = WorkflowResumeService(checkpointStore: store, engine: engine, eventBridge: makeEventBridge(), projectName: "kiteloop")

        do {
            try await service.resume(executionID: "exec-terminal")
            XCTFail("Resume at a terminal node should throw")
        } catch let error as WorkflowResumeError {
            XCTAssertEqual(error, .atTerminalNode(node: "done"))
        }

        let execution = await engine.execution(id: "exec-terminal")
        XCTAssertNil(execution, "A refused resume must not register an execution")

    }

    /// A checkpoint whose execution already settled cannot be continued either.
    func testResumeRefusesFinishedExecution() async throws {
        let (store, _) = try makeTempCheckpointStore()
        try await store.write(makeIncompleteCheckpoint(executionID: "exec-failed", status: .failed))

        let engine = WorkflowEngine(queueTimeout: 5.0)
        let service = WorkflowResumeService(checkpointStore: store, engine: engine, eventBridge: makeEventBridge(), projectName: "kiteloop")

        do {
            try await service.resume(executionID: "exec-failed")
            XCTFail("Resume of a finished execution should throw")
        } catch let error as WorkflowResumeError {
            XCTAssertEqual(error, .alreadyFinished(status: .failed))
        }

    }

    /// An execution parked on a terminal node has nothing left to continue, so
    /// the scan leaves it out entirely. Autopilot ends most runs on `blocked`
    /// or `done`, and listing those is what filled the prompt with hundreds of
    /// rows nobody could act on.
    func testScanExcludesExecutionsAtTerminalNodes() async throws {
        let (store, _) = try makeTempCheckpointStore()
        try await store.write(makeIncompleteCheckpoint(executionID: "exec-mid", currentNode: "node-0"))
        try await store.write(makeIncompleteCheckpoint(executionID: "exec-end", currentNode: "done"))

        let engine = WorkflowEngine(queueTimeout: 5.0)
        let service = WorkflowResumeService(checkpointStore: store, engine: engine, eventBridge: makeEventBridge(), projectName: "kiteloop")

        let incomplete = await service.scanForIncomplete()
        XCTAssertEqual(incomplete.map(\.id), ["exec-mid"])

    }

    /// With every execution settled there is nothing to ask about, and the
    /// prompt is shown only when the scan returns something.
    func testScanReturnsNothingWhenEveryExecutionIsSettled() async throws {
        let (store, _) = try makeTempCheckpointStore()
        for index in 0..<20 {
            try await store.write(makeIncompleteCheckpoint(executionID: "exec-blocked-\(index)", currentNode: "done"))
        }

        let engine = WorkflowEngine(queueTimeout: 5.0)
        let service = WorkflowResumeService(checkpointStore: store, engine: engine, eventBridge: makeEventBridge(), projectName: "kiteloop")

        let incomplete = await service.scanForIncomplete()
        XCTAssertTrue(incomplete.isEmpty, "Nothing resumable means no prompt at all")

    }

    func testStatePreambleReturnsFormattedString() async throws {
        let (store, _) = try makeTempCheckpointStore()
        let checkpoint = makeIncompleteCheckpoint(executionID: "exec-4")
        try await store.write(checkpoint)

        let engine = WorkflowEngine(queueTimeout: 5.0)
        let bridge = makeEventBridge()
        let service = WorkflowResumeService(checkpointStore: store, engine: engine, eventBridge: bridge, projectName: "kiteloop")

        let preamble = await service.statePreamble(for: "exec-4")
        XCTAssertNotNil(preamble)
        XCTAssertTrue(preamble!.contains("[RESUMED]"))
        XCTAssertTrue(preamble!.contains("Test Workflow"))
        XCTAssertTrue(preamble!.contains("node-0"))
        XCTAssertTrue(preamble!.contains("Continue from where you left off."))

    }

    func testStatePreambleReturnsNilForUnknownExecution() async throws {
        let (store, _) = try makeTempCheckpointStore()

        let engine = WorkflowEngine(queueTimeout: 5.0)
        let bridge = makeEventBridge()
        let service = WorkflowResumeService(checkpointStore: store, engine: engine, eventBridge: bridge, projectName: "kiteloop")

        let preamble = await service.statePreamble(for: "nonexistent")
        XCTAssertNil(preamble)

    }
}
