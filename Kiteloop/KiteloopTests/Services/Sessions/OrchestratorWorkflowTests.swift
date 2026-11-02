import XCTest
import KiteloopCore
@testable import Kiteloop

@MainActor
final class OrchestratorWorkflowTests: XCTestCase {
    private func makeOrchestrator() -> Orchestrator {
        Orchestrator(runtime: MockAgentRuntime())
    }

    func testStartWorkflowRegistersAndStarts() async throws {
        let orch = makeOrchestrator()
        let graph = WorkflowGraph(
            id: "orch-test", name: "OT", version: 1,
            nodes: [
                "n1": WorkflowNode(id: "n1", agentID: "a1", prompt: "p"),
                "n2": WorkflowNode(id: "n2", agentID: "a2", prompt: "p")
            ],
            edges: [WorkflowEdge(from: "n1", to: "n2", condition: .always)],
            entryNode: "n1", terminalNodes: ["n2"], metadata: .empty
        )

        let execID = try await orch.startWorkflow(graph: graph, initialState: ["x": .string("y")])
        XCTAssertFalse(execID.isEmpty)

        let mode = await orch.workflowEngine.routingMode(for: "a1")
        if case .graphControlled = mode { } else { XCTFail("Expected graphControlled") }
    }

    func testRoutingModeForFreeformAgent() async throws {
        let orch = makeOrchestrator()
        let mode = await orch.workflowEngine.routingMode(for: "unrelated")
        if case .freeform = mode { } else { XCTFail("Expected freeform") }
    }

    // MARK: - Node activation gate

    /// Records what a gate was asked, and lets a test read it back from the
    /// escaping closure the orchestrator holds.
    private final class GateLog {
        var asked: [String] = []
    }

    /// A one-node graph whose node writes `marker` when it runs — so "did this
    /// node run" is a file on disk rather than a mock's opinion.
    private func markerGraph(id: String, marker: URL) -> WorkflowGraph {
        WorkflowGraph(
            id: id, name: "Marker", version: 1,
            nodes: ["step": WorkflowNode(id: "step", prompt: "",
                                         shellCommand: "touch '\(marker.path(percentEncoded: false))'")],
            edges: [], entryNode: "step", terminalNodes: ["step"], metadata: .empty
        )
    }

    /// A gate that refuses means the node never runs — nothing is spawned, and
    /// nothing is spent. This is what keeps an autopilot run whose worker changed
    /// nothing from buying a reviewer pass over an empty diff.
    func testRefusingGateStopsTheNodeFromRunning() async throws {
        let dir = try makeTemporaryDirectory(prefix: "orchestrator-workflow")
        let marker = dir.appending(path: "ran.txt")

        let orch = makeOrchestrator()
        let log = GateLog()
        orch.nodeActivationGate = { _, nodeID in
            log.asked.append(nodeID)
            return false
        }

        _ = try await orch.startWorkflow(graph: markerGraph(id: "gate-refuses", marker: marker),
                                         initialState: ["_cwd": .string(dir.path(percentEncoded: false))])
        // A refused node leaves the execution parked with nothing to observe, so
        // this is a window: a node that did run would have touched the marker
        // well inside it.
        try await Task.sleep(for: .seconds(1))
        let ran = FileManager.default.fileExists(atPath: marker.path(percentEncoded: false))
        XCTAssertFalse(ran, "the gate refused, so the node must not have run")
        XCTAssertEqual(log.asked, ["step"], "the gate is asked before the node runs")
    }

    /// And a gate that agrees changes nothing: the node runs as it always did.
    func testAllowingGateLetsTheNodeRun() async throws {
        let dir = try makeTemporaryDirectory(prefix: "orchestrator-workflow")
        let marker = dir.appending(path: "ran.txt")

        let orch = makeOrchestrator()
        let log = GateLog()
        orch.nodeActivationGate = { _, nodeID in
            log.asked.append(nodeID)
            return true
        }

        _ = try await orch.startWorkflow(graph: markerGraph(id: "gate-allows", marker: marker),
                                         initialState: ["_cwd": .string(dir.path(percentEncoded: false))])
        try await eventually("the node to write its marker") {
            FileManager.default.fileExists(atPath: marker.path(percentEncoded: false))
        }
        let ran = FileManager.default.fileExists(atPath: marker.path(percentEncoded: false))
        XCTAssertTrue(ran, "an allowing gate must leave activation alone")
        XCTAssertEqual(log.asked, ["step"])
    }

    /// No gate installed is the default, and it activates everything — every
    /// workflow that isn't an autopilot run behaves exactly as before.
    func testWithoutAGateEveryNodeRuns() async throws {
        let dir = try makeTemporaryDirectory(prefix: "orchestrator-workflow")
        let marker = dir.appending(path: "ran.txt")

        let orch = makeOrchestrator()
        XCTAssertNil(orch.nodeActivationGate)
        _ = try await orch.startWorkflow(graph: markerGraph(id: "no-gate", marker: marker),
                                         initialState: ["_cwd": .string(dir.path(percentEncoded: false))])
        try await eventually("the node to write its marker") {
            FileManager.default.fileExists(atPath: marker.path(percentEncoded: false))
        }
        let ran = FileManager.default.fileExists(atPath: marker.path(percentEncoded: false))
        XCTAssertTrue(ran)
    }

    /// A shell node's result moves the workflow on: its completion carries no
    /// agent, and the engine used to refuse it for not matching the node's
    /// (absent) agent, so a run sat on its first shell node until the stall
    /// watchdog ended it.
    func testAShellNodesResultMovesTheWorkflowToTheNextNode() async throws {
        let dir = try makeTemporaryDirectory(prefix: "orchestrator-workflow-chain")
        let second = dir.appending(path: "second.txt")
        let graph = WorkflowGraph(
            id: "shell-chain", name: "Chain", version: 1,
            nodes: ["first": WorkflowNode(id: "first", prompt: "", shellCommand: "true"),
                    "second": WorkflowNode(id: "second", prompt: "",
                                           shellCommand: "touch '\(second.path(percentEncoded: false))'")],
            edges: [WorkflowEdge(from: "first", to: "second", condition: .always)],
            entryNode: "first", terminalNodes: ["second"], metadata: .empty
        )
        // Held for the whole test: a shell node reports back to its orchestrator
        // weakly, so one dropped after the start never hears the first node finish.
        let orchestrator = makeOrchestrator()
        _ = try await orchestrator.startWorkflow(graph: graph,
                                                 initialState: ["_cwd": .string(dir.path(percentEncoded: false))])
        try await eventually("the second node to run after the first passed") {
            FileManager.default.fileExists(atPath: second.path(percentEncoded: false))
        }
        withExtendedLifetime(orchestrator) {}
    }

    // MARK: - Gate-time state injection

    /// A one-node graph whose node runs `touch marker.txt` in whatever `_cwd`
    /// state hands it — relative, unlike `markerGraph`'s absolute path, so
    /// which directory receives the file depends on which `_cwd` the node was
    /// actually activated with.
    private func relativeMarkerGraph(id: String) -> WorkflowGraph {
        WorkflowGraph(
            id: id, name: "Marker", version: 1,
            nodes: ["step": WorkflowNode(id: "step", prompt: "", shellCommand: "touch marker.txt")],
            edges: [], entryNode: "step", terminalNodes: ["step"], metadata: .empty
        )
    }

    /// `activateWorkflowNode` fetches `execution` once, before asking the gate
    /// — so a gate that writes into state via `WorkflowEngine.mergeState`
    /// (`BacklogAutopilot`'s reviewer gate does, to hand the reviewer node its
    /// diff facts) must have that write reach the very node it just let
    /// through, not a snapshot the gate's own decision predates.
    func testAGateThatMergesStateReachesTheNodeItJustAllowed() async throws {
        let dir = try makeTemporaryDirectory(prefix: "orchestrator-workflow")
        let originalCwd = dir.appending(path: "original")
        let injectedCwd = dir.appending(path: "injected")
        try FileManager.default.createDirectory(at: originalCwd, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: injectedCwd, withIntermediateDirectories: true)

        let orch = makeOrchestrator()
        orch.nodeActivationGate = { executionID, _ in
            await orch.workflowEngine.mergeState(executionID: executionID,
                                                 updates: ["_cwd": .string(injectedCwd.path(percentEncoded: false))])
            return true
        }

        _ = try await orch.startWorkflow(graph: relativeMarkerGraph(id: "gate-merges-state"),
                                         initialState: ["_cwd": .string(originalCwd.path(percentEncoded: false))])

        let injectedMarker = injectedCwd.appending(path: "marker.txt").path(percentEncoded: false)
        try await eventually("the node to write its marker in the gate-injected directory") {
            FileManager.default.fileExists(atPath: injectedMarker)
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: originalCwd.appending(path: "marker.txt").path(percentEncoded: false)),
            "a stale state read would have run the shell command in the original directory instead")
    }

    func testCancelWorkflow() async throws {
        let orch = makeOrchestrator()
        let graph = WorkflowGraph(
            id: "cancel-test", name: "CT", version: 1,
            nodes: ["n1": WorkflowNode(id: "n1", agentID: "a1", prompt: "p")],
            edges: [], entryNode: "n1", terminalNodes: ["n1"], metadata: .empty
        )
        let execID = try await orch.startWorkflow(graph: graph, initialState: [:])
        await orch.cancelWorkflow(executionID: execID)

        let execution = await orch.workflowEngine.execution(id: execID)
        XCTAssertEqual(execution?.status, .cancelled)
    }

    // MARK: - Shell nodes

    /// Runs the helper off the main actor and returns what it reported, or nil
    /// if it had not returned within `within`.
    ///
    /// Bounded on purpose: the defect these cases cover is a helper that never
    /// returns, and an unbounded call would hang the suite rather than fail it.
    private func shellNodeResult(
        _ command: String,
        directory: String,
        executable: String = "/bin/bash",
        within: TimeInterval = 10.0
    ) async -> (status: Int32, output: String)? {
        let task = Task.detached {
            Orchestrator.runShellNodeCommand(command, directory: directory, executable: executable)
        }
        let done = expectation(description: "helper returned")
        let box = ResultBox()
        Task.detached {
            await box.set(task.value)
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: within)
        return await box.value
    }

    private actor ResultBox {
        var value: (status: Int32, output: String)?
        func set(_ v: (status: Int32, output: String)) { value = v }
    }

    /// The spawn failure this item is about: a `_cwd` naming a directory that
    /// has gone — a worktree cleaned up under a run. `Process.run()` throws, so
    /// nothing ever closes the parent's copy of the pipe's write end and a read
    /// would block for ever. The helper must return instead, with a non-zero
    /// status and output naming the failure.
    func testShellNodeInAMissingDirectoryFailsInsteadOfBlocking() async throws {
        let missing = FileManager.default.temporaryDirectory
            .appending(path: "gone-\(UUID().uuidString)")
            .path(percentEncoded: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing))

        let result = await shellNodeResult("echo hi", directory: missing)
        let got = try XCTUnwrap(result, "a command whose child cannot be spawned must return, not block")
        XCTAssertNotEqual(got.status, 0, "a failed spawn is not a passing node")
        XCTAssertTrue(got.output.contains("could not start command"),
                      "the output must say the command never started: \(got.output)")
    }

    /// The other way in: an executable that isn't there. Same arm, and the same
    /// guarantee that nothing reads the pipe after the throw.
    func testShellNodeWithAMissingExecutableFailsInsteadOfBlocking() async throws {
        let dir = try makeTemporaryDirectory(prefix: "orchestrator-workflow")

        let result = await shellNodeResult("echo hi",
                                           directory: dir.path(percentEncoded: false),
                                           executable: "/nonexistent/bash")
        let got = try XCTUnwrap(result, "a missing executable must return, not block")
        XCTAssertEqual(got.status, -1)
        XCTAssertTrue(got.output.contains("could not start command"), got.output)
    }

    /// A node that runs normally still reports what it did today: the child's
    /// exit status, and stdout and stderr merged into one stream.
    func testShellNodeReportsStatusAndMergedOutput() async throws {
        let dir = try makeTemporaryDirectory(prefix: "orchestrator-workflow")
        let cwd = dir.path(percentEncoded: false)

        let okResult = await shellNodeResult("echo out; echo err 1>&2", directory: cwd)
        let ok = try XCTUnwrap(okResult)
        XCTAssertEqual(ok.status, 0)
        XCTAssertTrue(ok.output.contains("out"), ok.output)
        XCTAssertTrue(ok.output.contains("err"), "stderr is merged into the same stream: \(ok.output)")

        let failedResult = await shellNodeResult("echo nope 1>&2; exit 3", directory: cwd)
        let failed = try XCTUnwrap(failedResult)
        XCTAssertEqual(failed.status, 3, "the child's own status is reported")
        XCTAssertTrue(failed.output.contains("nope"), failed.output)

        // The command runs *in* the directory it was given.
        let pwdResult = await shellNodeResult("pwd", directory: cwd)
        let pwd = try XCTUnwrap(pwdResult)
        XCTAssertEqual(pwd.status, 0)
        XCTAssertTrue(pwd.output.contains(dir.lastPathComponent), pwd.output)
    }

    /// A child cut off mid-character, or a tool printing one stray byte, must
    /// not cost the node its whole output: the readable text survives, and the
    /// bad bytes become replacement characters.
    func testShellNodeKeepsOutputAroundBytesThatAreNotUTF8() async throws {
        let dir = try makeTemporaryDirectory(prefix: "orchestrator-workflow")

        let result = await shellNodeResult(#"printf 'before\342\200after'; exit 3"#,
                                           directory: dir.path(percentEncoded: false))
        let got = try XCTUnwrap(result)
        XCTAssertEqual(got.status, 3)
        XCTAssertTrue(got.output.contains("before"), got.output)
        XCTAssertTrue(got.output.contains("after"), got.output)
    }

    /// Drain-then-wait: a child writing past the pipe buffer (~64KB) blocks on
    /// the write and never exits, so a helper that waited first would deadlock
    /// here and the bounded expectation would fail.
    func testShellNodeDrainsOutputLargerThanThePipeBuffer() async throws {
        let dir = try makeTemporaryDirectory(prefix: "orchestrator-workflow")

        let result = await shellNodeResult("for i in $(seq 1 20000); do echo 0123456789; done",
                                           directory: dir.path(percentEncoded: false))
        let got = try XCTUnwrap(result, "a child writing past the pipe buffer must not deadlock the helper")
        XCTAssertEqual(got.status, 0)
        XCTAssertGreaterThan(got.output.count, 65536, "the whole stream is drained, not one buffer's worth")
    }
}
