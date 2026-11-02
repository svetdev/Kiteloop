import XCTest
import KiteloopCore
@testable import Kiteloop

/// `TaskUpdate` is how an agent moves a task on the Agent Tasks panel, and the
/// only thing it ever learns about the call is the line it reads back. So what
/// these cover is that the line is true: a status the app cannot read — "done",
/// or none at all — is refused and named, rather than answered "updated." over a
/// panel still showing the old status, and the three spellings the schema
/// advertises still move the task exactly as they did.
@MainActor
final class ChatViewModelTaskUpdateTests: XCTestCase {
    private var tempDir: URL!
    private var runtime: MockAgentRuntime!
    private var orchestrator: Orchestrator!
    private var vm: ChatViewModel!

    override func setUp() async throws {
        tempDir = try makeTemporaryDirectory(prefix: "task-update-tests")

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

    /// Runs one Kiteloop-native tool call through the real stream-handling path
    /// and returns what the agent was told, which is the whole surface here.
    @discardableResult
    private func call(_ tool: String, _ input: String) async -> String {
        runtime.events = [
            .mcpToolCall(.init(requestID: "mcp-\(runtime.mcpToolResults.count)",
                               toolName: tool, input: input)),
            .result(.init(text: "done", costUSD: 0, durationMs: 1,
                          inputTokens: 1, outputTokens: 1,
                          cacheCreationInputTokens: 0, cacheReadInputTokens: 0,
                          sessionID: "s-a", permissionDenials: []))
        ]
        vm.inputText = "go"
        await vm.send()
        return runtime.mcpToolResults.last ?? ""
    }

    /// One pending task, as `TaskCreate` leaves it — the starting state for
    /// every update below.
    private func createTask() async {
        await call("TaskCreate", #"{"subject":"Ship it"}"#)
        XCTAssertEqual(vm.agentTasks.count, 1)
        XCTAssertEqual(vm.agentTasks.first?.status, .pending)
    }

    // MARK: - A status the app cannot read

    func testUnknownStatusIsRefusedAndLeavesTheTaskAlone() async {
        await createTask()
        let before = vm.agentTasks[0].updatedAt

        let result = await call("TaskUpdate", #"{"taskId":"1","status":"done"}"#)

        XCTAssertTrue(result.hasPrefix("Error:"), "got: \(result)")
        XCTAssertTrue(result.contains("pending"), "the refusal must name the vocabulary: \(result)")
        XCTAssertTrue(result.contains("in_progress"), "the refusal must name the vocabulary: \(result)")
        XCTAssertTrue(result.contains("completed"), "the refusal must name the vocabulary: \(result)")
        XCTAssertEqual(vm.agentTasks[0].status, .pending, "a refused call must not move the task")
        XCTAssertEqual(vm.agentTasks[0].updatedAt, before, "a refused call must not touch updatedAt")
    }

    func testMissingStatusIsRefusedTheSameWay() async {
        await createTask()
        let before = vm.agentTasks[0].updatedAt

        let result = await call("TaskUpdate", #"{"taskId":"1","subject":"Ship it twice"}"#)

        XCTAssertTrue(result.hasPrefix("Error:"), "got: \(result)")
        XCTAssertTrue(result.contains("in_progress"), "the refusal must name the vocabulary: \(result)")
        XCTAssertEqual(vm.agentTasks[0].subject, "Ship it", "a refused call changes nothing at all")
        XCTAssertEqual(vm.agentTasks[0].updatedAt, before, "a refused call must not touch updatedAt")
    }

    // MARK: - A status the app does read

    func testValidStatusStillMovesTheTask() async {
        await createTask()
        let before = vm.agentTasks[0].updatedAt

        let result = await call("TaskUpdate", #"{"taskId":"1","status":"in_progress"}"#)

        XCTAssertEqual(result, "Task #1 updated.")
        XCTAssertEqual(vm.agentTasks[0].status, .inProgress)
        XCTAssertGreaterThan(vm.agentTasks[0].updatedAt, before)
    }

    func testValidStatusStillCarriesSubjectAndDescription() async {
        await createTask()

        let result = await call(
            "TaskUpdate",
            #"{"taskId":"1","status":"completed","subject":"Shipped","description":"All of it"}"#
        )

        XCTAssertEqual(result, "Task #1 updated.")
        XCTAssertEqual(vm.agentTasks[0].status, .completed)
        XCTAssertEqual(vm.agentTasks[0].subject, "Shipped")
        XCTAssertEqual(vm.agentTasks[0].description, "All of it")
    }

    // MARK: - The refusals that were already there

    func testUnknownTaskIDStillReportsTheMissingTask() async {
        await createTask()

        let result = await call("TaskUpdate", #"{"taskId":"7","status":"done"}"#)

        XCTAssertEqual(result, "Error: No task with id '7'")
    }

    func testMissingTaskIDStillReportsTheMissingField() async {
        await createTask()

        let result = await call("TaskUpdate", #"{"status":"completed"}"#)

        XCTAssertEqual(result, "Error: TaskUpdate requires JSON with 'taskId' field.")
    }

    // MARK: - The panel belongs to the conversation on screen

    private func attachSessionStore() throws -> SessionStore {
        let dir = try makeTemporaryDirectory(prefix: "task-update-sessions")
        let store = SessionStore(projectDir: dir)
        vm.setupSessionStore(store)
        return store
    }

    func testClearingEmptiesTheTasks() async {
        await createTask()

        await vm.clear()

        XCTAssertTrue(vm.agentTasks.isEmpty)
    }

    func testNewChatEmptiesTheTasks() async throws {
        _ = try attachSessionStore()
        await createTask()

        await vm.startNewChat()

        XCTAssertTrue(vm.agentTasks.isEmpty)
    }

    func testSwitchingSessionEmptiesTheTasks() async throws {
        let store = try attachSessionStore()
        await createTask()
        let other = store.createSession(agentID: "a")

        await vm.switchToSession(other)

        XCTAssertTrue(vm.agentTasks.isEmpty)
    }

    func testAfterClearingTheNextTaskIsNumberOneAndUpdatesMoveIt() async {
        await createTask()
        await vm.clear()

        let created = await call("TaskCreate", #"{"subject":"Fresh start"}"#)
        let updated = await call("TaskUpdate", #"{"taskId":"1","status":"in_progress"}"#)

        XCTAssertEqual(created, "Task #1 created: Fresh start")
        XCTAssertEqual(updated, "Task #1 updated.")
        XCTAssertEqual(vm.agentTasks.count, 1)
        XCTAssertEqual(vm.agentTasks[0].subject, "Fresh start")
        XCTAssertEqual(vm.agentTasks[0].status, .inProgress)
    }
}
