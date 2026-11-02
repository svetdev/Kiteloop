import XCTest
import KiteloopCore
@testable import Kiteloop

/// The CLI's own `TaskCreate`/`TaskUpdate` arrive as `.toolUse` and the CLI
/// answers them itself. So all Kiteloop owes them is the Agent Tasks panel and
/// the transcript: nothing is sent back, and the turn keeps streaming. The
/// MCP tools of the same names are `ChatViewModelTaskUpdateTests`.
@MainActor
final class ChatViewModelCLITaskMirrorTests: XCTestCase {
    private var tempDir: URL!
    private var runtime: MockAgentRuntime!
    private var orchestrator: Orchestrator!
    private var vm: ChatViewModel!

    override func setUp() async throws {
        tempDir = try makeTemporaryDirectory(prefix: "cli-task-mirror-tests")

        let eventBus = EventBus(eventsURL: tempDir.appending(path: "events"))
        let subscriptionEngine = SubscriptionEngine(eventBus: eventBus)
        let project = KiteloopProject(rootURL: tempDir)
        let memoryManager = MemoryManager(project: project)
        runtime = MockAgentRuntime()
        orchestrator = Orchestrator(runtime: runtime, eventBus: eventBus,
                                    subscriptionEngine: subscriptionEngine, memoryManager: memoryManager)

        let agent = Agent(id: "a", name: "A", model: "sonnet",
                          systemPrompt: "", tools: ["TaskCreate", "TaskUpdate"], denied: [],
                          permissionMode: "default", state: .idle)
        orchestrator.addAgent(agent)
        try await orchestrator.startAgent("a", cwd: tempDir)

        vm = ChatViewModel(agentID: "a", projectURL: tempDir, orchestrator: orchestrator)
    }

    private var finalResult: StreamEvent {
        .result(.init(text: "done", costUSD: 0, durationMs: 1,
                      inputTokens: 1, outputTokens: 1,
                      cacheCreationInputTokens: 0, cacheReadInputTokens: 0,
                      sessionID: "s-a", permissionDenials: []))
    }

    /// One CLI task call, the CLI's own answer to it, then the end of the
    /// turn — a turn that stopped reading at the call never reaches the text.
    private func cliCall(_ tool: String, _ input: String, parent: String? = nil) async throws {
        let id = "tu-\(vm.messages.count)"
        runtime.events = [
            .toolUse(id: id, name: tool, input: input, parentToolUseID: parent),
            .toolResult(id: id, output: "ok", parentToolUseID: parent),
            .assistantText("after the call"),
            finalResult
        ]
        // A made-up answer would otherwise replay the whole turn.
        runtime.toolResultEvents = [finalResult]
        vm.inputText = "go"
        await vm.send()
        try await eventually("the turn ends") { !self.vm.isStreaming }
    }

    func testCreateOnlyMovesThePanelAndTheTranscript() async throws {
        try await cliCall("TaskCreate", #"{"subject":"Ship it","description":"d","activeForm":"Shipping"}"#)

        XCTAssertTrue(runtime.toolResultsSent.isEmpty)
        XCTAssertEqual(vm.agentTasks.count, 1)
        XCTAssertEqual(vm.agentTasks.first?.subject, "Ship it")
        XCTAssertEqual(vm.agentTasks.first?.description, "d")
        XCTAssertEqual(vm.agentTasks.first?.status, .pending)
        let calls = vm.messages.compactMap { message -> String? in
            if case .toolCall(let call) = message.content { return call.name }
            return nil
        }
        let results = vm.messages.compactMap { message -> String? in
            if case .toolResult(let result) = message.content { return result.toolCallID }
            return nil
        }
        XCTAssertEqual(calls, ["TaskCreate"])
        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(vm.messages.contains { if case .text("after the call") = $0.content { true } else { false } },
                      "the turn must keep streaming past the call")
    }

    func testUpdateMovesTheStatusAndSendsNothing() async throws {
        try await cliCall("TaskCreate", #"{"subject":"Ship it"}"#)
        let id = vm.agentTasks[0].id

        try await cliCall("TaskUpdate", #"{"taskId":"\#(id)","status":"in_progress"}"#)

        XCTAssertEqual(vm.agentTasks[0].status, .inProgress)
        XCTAssertTrue(runtime.toolResultsSent.isEmpty)
    }

    func testDeletedStatusRemovesTheTask() async throws {
        try await cliCall("TaskCreate", #"{"subject":"Ship it"}"#)
        let id = vm.agentTasks[0].id

        try await cliCall("TaskUpdate", #"{"taskId":"\#(id)","status":"deleted"}"#)

        XCTAssertTrue(vm.agentTasks.isEmpty)
        XCTAssertTrue(runtime.toolResultsSent.isEmpty)
    }

    func testUpdateWithoutStatusChangesTheSubjectAndKeepsTheStatus() async throws {
        try await cliCall("TaskCreate", #"{"subject":"Ship it"}"#)
        try await cliCall("TaskUpdate", #"{"taskId":"1","status":"in_progress"}"#)
        let before = vm.agentTasks[0].updatedAt

        try await cliCall("TaskUpdate", #"{"taskId":"1","subject":"Ship it twice"}"#)

        XCTAssertEqual(vm.agentTasks[0].subject, "Ship it twice")
        XCTAssertEqual(vm.agentTasks[0].status, .inProgress)
        XCTAssertGreaterThan(vm.agentTasks[0].updatedAt, before)
    }

    func testCreateAfterADeletionTakesANewID() async throws {
        try await cliCall("TaskCreate", #"{"subject":"First"}"#)
        try await cliCall("TaskUpdate", #"{"taskId":"1","status":"deleted"}"#)

        try await cliCall("TaskCreate", #"{"subject":"Second"}"#)

        XCTAssertEqual(vm.agentTasks.map(\.id), ["2"])
        XCTAssertEqual(vm.agentTasks.first?.subject, "Second")
    }

    func testUnknownTaskIDIsIgnored() async throws {
        try await cliCall("TaskCreate", #"{"subject":"Ship it"}"#)

        try await cliCall("TaskUpdate", #"{"taskId":"7","status":"completed"}"#)

        XCTAssertEqual(vm.agentTasks.map(\.status), [.pending])
        XCTAssertTrue(runtime.toolResultsSent.isEmpty)
    }

    func testASubagentsTaskCallMovesNothing() async throws {
        try await cliCall("TaskCreate", #"{"subject":"Not mine"}"#, parent: "agent-1")

        XCTAssertTrue(vm.agentTasks.isEmpty)
        XCTAssertTrue(runtime.toolResultsSent.isEmpty)
    }
}
