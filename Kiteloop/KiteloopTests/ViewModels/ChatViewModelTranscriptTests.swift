import XCTest
import KiteloopCore
@testable import Kiteloop

/// The write-time attribution half: that the run and role a turn belongs to are
/// resolved from the workflow reservation that owns it — the same source a turn
/// span is stamped from — and that ordinary conversation, owned by no run, is
/// not recorded as one.
@MainActor
final class ChatViewModelTranscriptTests: XCTestCase {

    private var tmpDir: URL!
    private var transcriptsURL: URL!

    override func setUpWithError() throws {
        tmpDir = try makeTemporaryDirectory(prefix: "kiteloop-vm-transcript")
        transcriptsURL = tmpDir.appending(path: "transcripts")
    }

    private func makeRuntime() -> MockAgentRuntime {
        let mock = MockAgentRuntime()
        mock.events = [
            .assistantText("Did the work"),
            .result(.init(
                text: "Did the work",
                costUSD: 0.001, durationMs: 100,
                inputTokens: 10, outputTokens: 5,
                cacheCreationInputTokens: 0, cacheReadInputTokens: 0,
                sessionID: "s1", permissionDenials: []
            ))
        ]
        return mock
    }

    private func makeOrchestrator(_ runtime: MockAgentRuntime) async throws -> Orchestrator {
        let orch = Orchestrator(runtime: runtime)
        orch.configureRunTranscripts(baseURL: transcriptsURL)
        orch.addAgent(Agent(
            id: "worker", name: "Worker", model: "sonnet",
            systemPrompt: "", tools: [],
            denied: [], permissionMode: "default", state: .idle
        ))
        try await orch.startAgent("worker", cwd: tmpDir)
        return orch
    }

    /// Reserves the agent for a run without activating the node — activation
    /// posts `.agentTriggered`, which would drive a second turn the assertions
    /// would then have to disentangle.
    private func startRun(_ orch: Orchestrator, role: String) async throws -> String {
        let graph = WorkflowGraph(
            id: "graph-\(role)", name: "G", version: 1,
            nodes: [role: WorkflowNode(id: role, agentID: "worker", prompt: "p")],
            edges: [], entryNode: role, terminalNodes: [role], metadata: .empty
        )
        await orch.workflowEngine.register(graph: graph)
        return try await orch.workflowEngine.start(graphID: graph.id, initialState: [:])
    }

    /// The writes are handed off and never awaited on the run's path, so a test
    /// has to wait for them the way anything else observing them would.
    private func records(
        _ store: RunTranscriptStore, of executionID: String, atLeast expected: Int,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws -> [RunTranscriptStore.Record] {
        try await eventuallyValue("at least \(expected) transcript records of \(executionID)", file: file, line: line) {
            let found = await store.records(of: executionID)
            return found.count >= expected ? found : nil
        }
    }

    // MARK: - Tests

    func testTurnRecordsCarryTheRunAndRoleThatOwnsThem() async throws {
        let orch = try await makeOrchestrator(makeRuntime())
        let execID = try await startRun(orch, role: "worker")
        let store = try XCTUnwrap(orch.runTranscriptStore)

        let vm = ChatViewModel(agentID: "worker", projectURL: tmpDir, orchestrator: orch)
        vm.inputText = "build the thing"
        await vm.send()

        let records = try await records(store, of: execID, atLeast: 2)
        XCTAssertGreaterThanOrEqual(records.count, 2)
        XCTAssertTrue(records.allSatisfy { $0.executionID == execID })
        XCTAssertTrue(records.allSatisfy { $0.role == "worker" })
        XCTAssertTrue(records.allSatisfy { $0.agentID == "worker" })

        let texts = records.compactMap { record -> String? in
            if case .text(let t) = record.message.content { return t }
            return nil
        }
        XCTAssertTrue(texts.contains("build the thing"), "the transcript opens with the run's instruction")
        XCTAssertTrue(texts.contains("Did the work"), "and carries what the agent produced")
    }

    func testASecondRunByTheSameAgentDoesNotOverwriteTheFirst() async throws {
        let orch = try await makeOrchestrator(makeRuntime())
        let store = try XCTUnwrap(orch.runTranscriptStore)

        let firstExec = try await startRun(orch, role: "worker")
        let vm = ChatViewModel(agentID: "worker", projectURL: tmpDir, orchestrator: orch)
        vm.inputText = "first item"
        await vm.send()
        _ = try await records(store, of: firstExec, atLeast: 2)
        await orch.workflowEngine.cancel(executionID: firstExec)

        let secondExec = try await startRun(orch, role: "reviewer")
        vm.inputText = "second item"
        await vm.send()

        let second = try await records(store, of: secondExec, atLeast: 2)
        let first = await store.records(of: firstExec)

        XCTAssertNotEqual(firstExec, secondExec)
        XCTAssertGreaterThanOrEqual(first.count, 2, "the earlier run's transcript must survive the later run")
        XCTAssertTrue(first.allSatisfy { $0.role == "worker" })
        XCTAssertTrue(second.allSatisfy { $0.role == "reviewer" })

        let firstTexts = first.compactMap { record -> String? in
            if case .text(let t) = record.message.content { return t }
            return nil
        }
        XCTAssertTrue(firstTexts.contains("first item"))
        XCTAssertFalse(firstTexts.contains("second item"), "runs must not bleed into each other")
    }

    /// A human chatting to an agent is owned by no run, so it belongs in the chat
    /// session — recording it here would put conversation in a run's evidence.
    func testConversationOwnedByNoRunIsNotRecorded() async throws {
        let orch = try await makeOrchestrator(makeRuntime())
        let store = try XCTUnwrap(orch.runTranscriptStore)

        let vm = ChatViewModel(agentID: "worker", projectURL: tmpDir, orchestrator: orch)
        vm.inputText = "just asking"
        await vm.send()
        try await Task.sleep(nanoseconds: 300_000_000)

        let usage = await store.usage()
        XCTAssertEqual(usage.runs, 0)
    }

    /// Transcript writing must not be able to fail a run: with a base directory
    /// that can never be created, the turn still completes and its messages are
    /// still there.
    func testAFailingTranscriptWriteDoesNotFailTheRun() async throws {
        let blocker = tmpDir.appending(path: "blocker")
        try Data("not a directory".utf8).write(to: blocker)

        let orch = Orchestrator(runtime: makeRuntime())
        orch.configureRunTranscripts(baseURL: blocker.appending(path: "transcripts"))
        orch.addAgent(Agent(
            id: "worker", name: "Worker", model: "sonnet",
            systemPrompt: "", tools: [],
            denied: [], permissionMode: "default", state: .idle
        ))
        try await orch.startAgent("worker", cwd: tmpDir)
        let execID = try await startRun(orch, role: "worker")

        let vm = ChatViewModel(agentID: "worker", projectURL: tmpDir, orchestrator: orch)
        vm.inputText = "build the thing"
        await vm.send()

        XCTAssertFalse(vm.isStreaming, "the turn completed")
        XCTAssertTrue(vm.messages.contains { record in
            if case .text(let t) = record.content { return t == "Did the work" }
            return false
        }, "the run's own messages are unaffected by the failed write")
        let store = try XCTUnwrap(orch.runTranscriptStore)
        let status = await store.status(of: execID)
        XCTAssertEqual(status, .absent)
    }
}
