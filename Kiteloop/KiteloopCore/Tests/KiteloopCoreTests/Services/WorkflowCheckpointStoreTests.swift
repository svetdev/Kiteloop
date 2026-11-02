import XCTest
@testable import KiteloopCore

final class WorkflowCheckpointStoreTests: XCTestCase {
    private var tempDir: URL!
    private var store: WorkflowCheckpointStore!

    override func setUp() async throws {
        tempDir = try makeTemporaryDirectory(prefix: "checkpoint-tests")
        store = WorkflowCheckpointStore(baseURL: tempDir)
    }

    func testWriteAndLoad() async throws {
        let graph = WorkflowGraph(
            id: "g1", name: "Test", version: 1,
            nodes: ["n1": WorkflowNode(id: "n1", agentID: "a1", prompt: "p")],
            edges: [], entryNode: "n1", terminalNodes: ["n1"], metadata: .empty
        )
        let execution = WorkflowExecution(
            id: "exec-1", graphID: "g1", graphVersion: 1,
            currentNode: "n1", status: .running, state: ["key": .string("value")]
        )
        let checkpoint = WorkflowCheckpoint(
            id: "cp-1", executionID: "exec-1",
            graphSnapshot: graph, executionSnapshot: execution,
            checkpointedAt: Date(), reason: .nodeTransition
        )

        try await store.write(checkpoint)
        let loaded = try await store.load(executionID: "exec-1", checkpointID: "cp-1")
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.executionSnapshot.state["key"], .string("value"))
    }

    /// Rewriting the same execution/checkpoint id replaces the file in one step,
    /// and what `load` reads back afterwards is the new content — not the old one
    /// left behind by a rename that never happened.
    func testWriteOverAnExistingCheckpointLoadsTheNewContent() async throws {
        let graph = makeGraph()
        for node in ["n1", "done"] {
            let execution = WorkflowExecution(
                id: "exec-over", graphID: "g1", graphVersion: 1,
                currentNode: node, status: .running, state: ["at": .string(node)]
            )
            try await store.write(WorkflowCheckpoint(
                id: "cp-over", executionID: "exec-over", graphSnapshot: graph,
                executionSnapshot: execution, checkpointedAt: Date(), reason: .nodeTransition
            ))
        }

        let loaded = try await store.load(executionID: "exec-over", checkpointID: "cp-over")
        XCTAssertEqual(loaded?.executionSnapshot.currentNode, "done")
        XCTAssertEqual(loaded?.executionSnapshot.state["at"], .string("done"))
    }

    /// The temp sibling the write goes through is renamed into place, so the
    /// execution directory holds the checkpoints and nothing else — a leftover
    /// `.tmp` would accumulate one per write and sit next to the real files.
    func testWriteLeavesNoTempSiblingBehind() async throws {
        let graph = makeGraph()
        let execution = WorkflowExecution(
            id: "exec-tmp", graphID: "g1", graphVersion: 1,
            currentNode: "n1", status: .running, state: [:]
        )
        for id in ["cp-1", "cp-1", "cp-2"] {
            try await store.write(WorkflowCheckpoint(
                id: id, executionID: "exec-tmp", graphSnapshot: graph,
                executionSnapshot: execution, checkpointedAt: Date(), reason: .nodeTransition
            ))
        }

        let contents = try FileManager.default.contentsOfDirectory(
            atPath: tempDir.appending(path: "exec-tmp").path
        ).sorted()
        XCTAssertEqual(contents, ["cp-1.checkpoint.json", "cp-2.checkpoint.json"])
    }

    func testLatestCheckpointForExecution() async throws {
        let graph = WorkflowGraph(
            id: "g1", name: "Test", version: 1,
            nodes: ["n1": WorkflowNode(id: "n1", agentID: "a1", prompt: "p")],
            edges: [], entryNode: "n1", terminalNodes: ["n1"], metadata: .empty
        )
        let exec = WorkflowExecution(
            id: "exec-2", graphID: "g1", graphVersion: 1,
            currentNode: "n1", status: .running, state: [:]
        )
        let cp1 = WorkflowCheckpoint(
            id: "cp-1", executionID: "exec-2", graphSnapshot: graph,
            executionSnapshot: exec, checkpointedAt: Date().addingTimeInterval(-10), reason: .started
        )
        let cp2 = WorkflowCheckpoint(
            id: "cp-2", executionID: "exec-2", graphSnapshot: graph,
            executionSnapshot: exec, checkpointedAt: Date(), reason: .nodeTransition
        )
        try await store.write(cp1)
        try await store.write(cp2)

        let latest = try await store.latestCheckpoint(executionID: "exec-2")
        XCTAssertEqual(latest?.id, "cp-2")
    }

    /// The stamp is encoded to milliseconds, so a workflow's start and its first
    /// transition can carry the same one. The transition is still the checkpoint
    /// a resume should pick up from.
    func testLatestCheckpointOnAnEqualStampIsTheOneWrittenSecond() async throws {
        let graph = makeGraph()
        let stamp = Date()
        let started = WorkflowExecution(
            id: "exec-tie", graphID: "g1", graphVersion: 1,
            currentNode: "n1", status: .running, state: [:]
        )
        let transitioned = WorkflowExecution(
            id: "exec-tie", graphID: "g1", graphVersion: 1,
            currentNode: "done", status: .running, state: ["findings": .string("two")]
        )
        try await store.write(WorkflowCheckpoint(
            id: "cp-1-start", executionID: "exec-tie", graphSnapshot: graph,
            executionSnapshot: started, checkpointedAt: stamp, reason: .started
        ))
        try await store.write(WorkflowCheckpoint(
            id: "cp-2-transition", executionID: "exec-tie", graphSnapshot: graph,
            executionSnapshot: transitioned, checkpointedAt: stamp, reason: .nodeTransition
        ))

        let latest = try await store.latestCheckpoint(executionID: "exec-tie")
        XCTAssertEqual(latest?.id, "cp-2-transition")
        XCTAssertEqual(latest?.executionSnapshot.currentNode, "done")
        XCTAssertEqual(latest?.executionSnapshot.state["findings"], .string("two"))

        // Same directory, same answer: nothing here may depend on the order the
        // enumerator happens to hand the files back in.
        for _ in 0..<10 {
            let again = try await store.latestCheckpoint(executionID: "exec-tie")
            XCTAssertEqual(again?.id, "cp-2-transition")
        }
    }

    /// The mtime is what carries write order once the stamps tie, so it has to
    /// outrank the filename — here the file written second sorts first by name.
    func testLatestCheckpointOnAnEqualStampPrefersTheLaterModifiedFile() async throws {
        let graph = makeGraph()
        let stamp = Date()
        let execution = WorkflowExecution(
            id: "exec-mtime", graphID: "g1", graphVersion: 1,
            currentNode: "n1", status: .running, state: [:]
        )
        for id in ["cp-a", "cp-z"] {
            try await store.write(WorkflowCheckpoint(
                id: id, executionID: "exec-mtime", graphSnapshot: graph,
                executionSnapshot: execution, checkpointedAt: stamp, reason: .nodeTransition
            ))
        }

        // `cp-a` is the later write, whatever the filesystem clock's resolution
        // had to say about two writes microseconds apart.
        let dir = tempDir.appending(path: "exec-mtime")
        try FileManager.default.setAttributes(
            [.modificationDate: stamp.addingTimeInterval(-1)],
            ofItemAtPath: dir.appending(path: "cp-z.checkpoint.json").path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: stamp],
            ofItemAtPath: dir.appending(path: "cp-a.checkpoint.json").path
        )

        let latest = try await store.latestCheckpoint(executionID: "exec-mtime")
        XCTAssertEqual(latest?.id, "cp-a")
    }

    /// A `n1` → `done` graph, `done` terminal — enough to tell a run still
    /// mid-graph from one parked at the end of it.
    private func makeGraph() -> WorkflowGraph {
        WorkflowGraph(
            id: "g1", name: "Test", version: 1,
            nodes: [
                "n1": WorkflowNode(id: "n1", agentID: "a1", prompt: "p"),
                "done": WorkflowNode(id: "done", agentID: "a1", prompt: ""),
            ],
            edges: [WorkflowEdge(from: "n1", to: "done", condition: .always)],
            entryNode: "n1", terminalNodes: ["done"], metadata: .empty
        )
    }

    /// `now` defaults to `checkpointedAt` rather than the real clock: the
    /// existing prune-only tests backdate `checkpointedAt` to build settled
    /// fixtures, and since `write` now sweeps on its own, defaulting `now` to
    /// the real clock would let that first write immediately prune the very
    /// fixture the test is about to assert on with an explicit
    /// `pruneSettledExecutions()` call.
    private func writeCheckpoint(
        executionID: String,
        currentNode: String = "n1",
        status: ExecutionStatus = .running,
        checkpointedAt: Date = Date(),
        now: Date? = nil
    ) async throws {
        let execution = WorkflowExecution(
            id: executionID, graphID: "g1", graphVersion: 1,
            currentNode: currentNode, status: status, state: [:]
        )
        try await store.write(WorkflowCheckpoint(
            id: "cp-\(executionID)", executionID: executionID, graphSnapshot: makeGraph(),
            executionSnapshot: execution, checkpointedAt: checkpointedAt, reason: .nodeTransition
        ), now: now ?? checkpointedAt)
    }

    func testListIncompleteExecutions() async throws {
        try await writeCheckpoint(executionID: "exec-r", status: .running)
        try await writeCheckpoint(executionID: "exec-c", status: .completed)

        let incomplete = try await store.listIncompleteExecutions()
        XCTAssertEqual(incomplete.count, 1)
        XCTAssertEqual(incomplete.first?.executionID, "exec-r")
    }

    /// Autopilot leaves most runs sitting on `blocked`/`done` with the status
    /// still reading `running`. Nothing follows a terminal node, so those are
    /// not incomplete however their status reads.
    func testListIncompleteExcludesExecutionsParkedOnATerminalNode() async throws {
        try await writeCheckpoint(executionID: "exec-mid", currentNode: "n1", status: .running)
        try await writeCheckpoint(executionID: "exec-parked", currentNode: "done", status: .running)

        let incomplete = try await store.listIncompleteExecutions()
        XCTAssertEqual(incomplete.map(\.executionID), ["exec-mid"])
    }

    // MARK: - Pruning

    /// Settled executions past the retention window are the only thing pruning
    /// removes — and it is what stops one project accruing 495 execution
    /// directories that no resume will ever read.
    func testPruneRemovesSettledExecutionsPastRetention() async throws {
        let old = Date().addingTimeInterval(-48 * 60 * 60)
        try await writeCheckpoint(executionID: "exec-done", currentNode: "done", checkpointedAt: old)
        try await writeCheckpoint(executionID: "exec-failed", status: .failed, checkpointedAt: old)
        try await writeCheckpoint(executionID: "exec-cancelled", status: .cancelled, checkpointedAt: old)

        let removed = try await store.pruneSettledExecutions()

        XCTAssertEqual(removed, 3)
        for executionID in ["exec-done", "exec-failed", "exec-cancelled"] {
            let latest = try await store.latestCheckpoint(executionID: executionID)
            XCTAssertNil(latest, "\(executionID) should have been pruned")
        }
    }

    /// Pruning must never take a checkpoint an offered execution depends on:
    /// what the prompt lists is exactly what is not settled.
    func testPruneKeepsResumableExecutionsHoweverOld() async throws {
        let ancient = Date().addingTimeInterval(-365 * 24 * 60 * 60)
        try await writeCheckpoint(executionID: "exec-live", currentNode: "n1", status: .running, checkpointedAt: ancient)
        try await writeCheckpoint(executionID: "exec-paused", currentNode: "n1", status: .paused, checkpointedAt: ancient)
        try await writeCheckpoint(executionID: "exec-old-done", currentNode: "done", checkpointedAt: ancient)

        let removed = try await store.pruneSettledExecutions()

        XCTAssertEqual(removed, 1)
        let survivors = try await store.listIncompleteExecutions().map(\.executionID).sorted()
        XCTAssertEqual(survivors, ["exec-live", "exec-paused"])
    }

    /// A run that settled minutes ago is still worth looking at, so it stays
    /// until the window passes.
    func testPruneKeepsRecentlySettledExecutions() async throws {
        try await writeCheckpoint(executionID: "exec-just-done", currentNode: "done", checkpointedAt: Date())

        let removed = try await store.pruneSettledExecutions()

        XCTAssertEqual(removed, 0)
        let latest = try await store.latestCheckpoint(executionID: "exec-just-done")
        XCTAssertNotNil(latest)
    }

    /// What cannot be evaluated is not deleted: an unreadable directory might
    /// hold a resumable run, and pruning is not the place to find out.
    func testPruneLeavesUnreadableDirectoriesAlone() async throws {
        let junkDir = tempDir.appending(path: "exec-junk")
        try FileManager.default.createDirectory(at: junkDir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: junkDir.appending(path: "broken.checkpoint.json"))

        let removed = try await store.pruneSettledExecutions()

        XCTAssertEqual(removed, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: junkDir.path))
    }

    // MARK: - Write-triggered pruning

    /// A store nobody reopens still sweeps: a write into a directory holding a
    /// settled execution past retention takes it with it, with no project-open
    /// sweep involved.
    func testWriteSweepsSettledExecutionsPastRetention() async throws {
        // Written with `now` equal to its own `checkpointedAt`, so this first
        // ever write's own sweep (always due) finds nothing stale yet.
        try await writeCheckpoint(executionID: "exec-old", currentNode: "done", status: .completed, checkpointedAt: .now)

        // A write far enough later is due for its own sweep and finds exec-old
        // settled and past retention.
        let later = Date.now.addingTimeInterval(WorkflowCheckpointStore.Defaults.settledRetention + 60)
        try await writeCheckpoint(executionID: "exec-new", checkpointedAt: later, now: later)

        let sweptAway = try await store.latestCheckpoint(executionID: "exec-old")
        XCTAssertNil(sweptAway)
        let justWritten = try await store.latestCheckpoint(executionID: "exec-new")
        XCTAssertNotNil(justWritten)
    }

    /// The sweep is throttled to once per `Defaults.pruneInterval`: a write
    /// inside that window leaves a stale settled execution alone, and a write
    /// once the window has passed sweeps it — proven through the injected
    /// `now`, not by waiting.
    func testWriteSweepIsThrottled() async throws {
        let start = Date.now

        // Establishes `lastPruneAt` at `start` via the always-due first sweep.
        try await writeCheckpoint(executionID: "exec-seed", checkpointedAt: start, now: start)

        // Settled and already far past retention however `now` is read, but
        // written inside the throttle window so this write's own sweep is
        // skipped and cannot delete it on the spot.
        let veryOld = start.addingTimeInterval(-100 * 24 * 60 * 60)
        let insideWindow = start.addingTimeInterval(10 * 60)
        try await writeCheckpoint(executionID: "exec-stale", currentNode: "done", status: .completed, checkpointedAt: veryOld, now: insideWindow)

        // Still inside the throttle window measured from `start`: the sweep
        // must not run, so the stale execution survives.
        let stillInsideWindow = start.addingTimeInterval(40 * 60)
        try await writeCheckpoint(executionID: "exec-mid", checkpointedAt: stillInsideWindow, now: stillInsideWindow)
        let stillThere = try await store.latestCheckpoint(executionID: "exec-stale")
        XCTAssertNotNil(stillThere, "a write inside the prune interval must not sweep")

        // Past the throttle window: this write is due and sweeps exec-stale.
        let pastWindow = start.addingTimeInterval(WorkflowCheckpointStore.Defaults.pruneInterval + 60)
        try await writeCheckpoint(executionID: "exec-late", checkpointedAt: pastWindow, now: pastWindow)
        let swept = try await store.latestCheckpoint(executionID: "exec-stale")
        XCTAssertNil(swept, "a write past the prune interval must sweep")

        // The checkpoint each of those writes put down is unaffected by the sweep.
        for executionID in ["exec-seed", "exec-mid", "exec-late"] {
            let loaded = try await store.latestCheckpoint(executionID: executionID)
            XCTAssertNotNil(loaded, "\(executionID) should still be on disk and loadable")
        }
    }

    /// A write-triggered sweep leaves alone exactly what
    /// `pruneSettledExecutions(retention:now:)` already leaves alone: an
    /// unsettled execution however old, a settled one inside the retention
    /// window, and a directory whose checkpoints cannot be decoded.
    func testWriteTriggeredSweepLeavesTheSameExecutionsAlone() async throws {
        let start = Date.now
        try await writeCheckpoint(executionID: "exec-seed", checkpointedAt: start, now: start)

        // Past the throttle window and past retention for anything settled
        // since `start`: this write's own sweep runs.
        let later = start.addingTimeInterval(WorkflowCheckpointStore.Defaults.settledRetention + WorkflowCheckpointStore.Defaults.pruneInterval)

        let ancient = start.addingTimeInterval(-365 * 24 * 60 * 60)
        try await writeCheckpoint(executionID: "exec-live", currentNode: "n1", status: .running, checkpointedAt: ancient, now: start.addingTimeInterval(5 * 60))
        // Settled an hour before the sweep runs: inside the retention window
        // as of `later`, however old it reads relative to `start`.
        let recentlySettled = later.addingTimeInterval(-60 * 60)
        try await writeCheckpoint(executionID: "exec-recent-done", currentNode: "done", status: .completed, checkpointedAt: recentlySettled, now: start.addingTimeInterval(10 * 60))

        let junkDir = tempDir.appending(path: "exec-junk")
        try FileManager.default.createDirectory(at: junkDir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: junkDir.appending(path: "broken.checkpoint.json"))

        try await writeCheckpoint(executionID: "exec-trigger", checkpointedAt: later, now: later)

        let live = try await store.latestCheckpoint(executionID: "exec-live")
        XCTAssertNotNil(live, "unsettled survives however old")
        let recentDone = try await store.latestCheckpoint(executionID: "exec-recent-done")
        XCTAssertNotNil(recentDone, "settled inside the window survives")
        XCTAssertTrue(FileManager.default.fileExists(atPath: junkDir.path), "unreadable directory is left alone")
        let trigger = try await store.latestCheckpoint(executionID: "exec-trigger")
        XCTAssertNotNil(trigger, "the checkpoint just written stays on disk")
    }

    func testDeleteCheckpoints() async throws {
        let graph = WorkflowGraph(
            id: "g1", name: "Test", version: 1,
            nodes: ["n1": WorkflowNode(id: "n1", agentID: "a1", prompt: "p")],
            edges: [], entryNode: "n1", terminalNodes: ["n1"], metadata: .empty
        )
        let exec = WorkflowExecution(
            id: "exec-d", graphID: "g1", graphVersion: 1,
            currentNode: "n1", status: .completed, state: [:]
        )
        try await store.write(WorkflowCheckpoint(
            id: "cp-d", executionID: "exec-d", graphSnapshot: graph,
            executionSnapshot: exec, checkpointedAt: Date(), reason: .completed
        ))

        try await store.deleteCheckpoints(executionID: "exec-d")
        let loaded = try await store.latestCheckpoint(executionID: "exec-d")
        XCTAssertNil(loaded)
    }
}
