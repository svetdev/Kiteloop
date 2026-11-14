import XCTest
import KiteloopCore
@testable import Kiteloop

/// Answering what an agent's session stopped to ask, changing its mode and
/// stopping one of its tasks from the phone — each through the same
/// view-model call the Mac's own control makes. Driven over a real loopback
/// socket against a scripted runtime.
@MainActor
final class KiteloopControlServerAgentPromptTests: XCTestCase {

    private var tempDir: URL!
    private var registry: ControlSessionRegistry!
    private var harness: ControlServerHarness!
    private var runtime: MockAgentRuntime!

    override func setUp() async throws {
        tempDir = try makeTemporaryDirectory(prefix: "control-agent-prompts")
        registry = ControlSessionRegistry()
        runtime = MockAgentRuntime()
        harness = try await ControlServerHarness.start(registry: registry)
    }

    override func tearDown() async throws {
        harness?.stop()
        harness = nil
        registry = nil
        runtime = nil
    }

    // MARK: - Helpers

    private static func done(_ text: String) -> StreamEvent.ResultPayload {
        .init(text: text, costUSD: 0.01, durationMs: 500, inputTokens: 100, outputTokens: 50,
              cacheCreationInputTokens: 0, cacheReadInputTokens: 0, sessionID: "s1", permissionDenials: [])
    }

    /// A project with one agent whose session has run a turn, so it is live.
    private func liveAgent(turn events: [StreamEvent] = []) async throws -> ChatViewModel {
        let root = tempDir.appendingPathComponent("alpha", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let rootURL = URL(fileURLWithPath: root.path(percentEncoded: false), isDirectory: false)
        let project = KiteloopProject(rootURL: rootURL)
        try project.ensureDirectoryExists()
        let eventBus = EventBus(eventsURL: project.eventsURL)
        let orchestrator = Orchestrator(runtime: runtime, eventBus: eventBus,
                                        subscriptionEngine: SubscriptionEngine(eventBus: eventBus),
                                        memoryManager: MemoryManager(project: project))
        let session = ProjectSession(
            project: project, projectURL: rootURL, orchestrator: orchestrator,
            sessionStore: SessionStore(projectDir: rootURL),
            knowledgeStore: AgentKnowledgeStore(baseURL: project.knowledgeURL),
            knowledgeIndex: KnowledgeIndex(baseURL: project.knowledgeURL),
            context: ProjectSessionContext(
                runtimeFactory: { [runtime] in runtime! },
                agentCatalogStore: AgentCatalogStore(storageURL: tempDir.appendingPathComponent("catalog.json")),
                packageResolver: nil,
                globalConfigStore: GlobalConfigStore(storageURL: tempDir.appendingPathComponent("global.json")),
                orgManifestLoader: OrgManifestLoader(),
                repoCloneService: RepoCloneService()))
        registry.register(session: session, autopilot: BacklogAutopilot())
        let agent = Agent(name: "Builder", model: "sonnet", systemPrompt: "", tools: [], denied: [], permissionMode: "default")
        orchestrator.addAgent(agent)
        runtime.events = events + [.result(Self.done("ok"))]
        _ = try await harness.post("/v1/agents/message",
                                   ["project": "alpha", "agent": "Builder", "message": "go", "wait": true], timeout: 30)
        return try XCTUnwrap(session.chatViewModels[agent.id])
    }

    private func ask(_ vm: ChatViewModel, _ request: PermissionPrompt.Request) async throws {
        let before = vm.openPromptCount
        runtime.prompt(.request(request))
        try await eventually("the card to open") { vm.openPromptCount == before + 1 }
    }

    private var bash: PermissionPrompt.Request {
        PermissionPrompt.Request(id: "req-1", toolName: "Bash", input: #"{"command":"make"}"#,
                                 suggestions: [.init(label: "Always allow Bash(make) in this project", json: #"{"type":"addRules"}"#)])
    }

    private func body(_ extra: [String: Any]) -> [String: Any] {
        ["project": "alpha", "agent": "Builder"].merging(extra) { _, new in new }
    }

    private func answered(_ id: String) -> [String: Any]? {
        guard let line = runtime.controlLines.last(where: { $0.contains(id) }),
              let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return nil }
        return (json["response"] as? [String: Any])?["response"] as? [String: Any]
    }

    // MARK: - Permission

    func testAnOpenPermissionCardReachesTheTranscriptWithWhatAlwaysWouldRemember() async throws {
        let vm = try await liveAgent()
        try await ask(vm, bash)

        let (_, transcript) = try await harness.get("/v1/agents/transcript?project=alpha&agent=Builder")

        let messages = try XCTUnwrap(transcript["messages"] as? [[String: Any]])
        let card = try XCTUnwrap(messages.first { $0["kind"] as? String == "permission" })
        XCTAssertEqual(card["text"] as? String, "make")
        let state = try XCTUnwrap(card["permission"] as? [String: Any])
        XCTAssertEqual(state["request"] as? String, "req-1")
        XCTAssertEqual(state["open"] as? Bool, true)
        XCTAssertEqual(state["always"] as? [String], ["Always allow Bash(make) in this project"])
    }

    func testAllowAnswersTheSession() async throws {
        let vm = try await liveAgent()
        try await ask(vm, bash)

        let (status, answer) = try await harness.post("/v1/agents/permission", body(["request": "req-1", "answer": "allow"]))

        XCTAssertEqual(status, 200)
        XCTAssertEqual(answer["answer"] as? String, "allow")
        XCTAssertEqual(answered("req-1")?["behavior"] as? String, "allow")
        XCTAssertNil(answered("req-1")?["updatedPermissions"])
        XCTAssertEqual(vm.openPromptCount, 0)
    }

    func testAnAllowWithTheCommandRewordedRunsTheRewordingAndTheCardSaysSo() async throws {
        let vm = try await liveAgent()
        try await ask(vm, bash)

        let (status, answer) = try await harness.post("/v1/agents/permission",
                                                      body(["request": "req-1", "answer": "allow", "input": ["command": "make test"]]))

        XCTAssertEqual(status, 200)
        XCTAssertEqual(answer["edited"] as? Bool, true)
        XCTAssertEqual((answered("req-1")?["updatedInput"] as? [String: Any])?["command"] as? String, "make test")
        let (_, transcript) = try await harness.get("/v1/agents/transcript?project=alpha&agent=Builder")
        let card = try XCTUnwrap((transcript["messages"] as? [[String: Any]])?.first { $0["kind"] as? String == "permission" })
        let state = try XCTUnwrap(card["permission"] as? [String: Any])
        XCTAssertEqual(state["edited"] as? Bool, true)
        XCTAssertEqual(state["fields"] as? [[String: String]], [["name": "command", "value": "make test"]])
        try await eventually("the agent is told how its call ran") {
            self.runtime.sentMessages.contains { $0.message == "I changed your Bash call before allowing it. It ran with:\n\ncommand: make test" }
                || vm.messages.contains { message in
                    if case .text(let text) = message.content { return text.hasPrefix("I changed your Bash call") }
                    return false
                }
        }
    }

    func testAnInputThatIsNotTextOrComesWithADenyIs400AndOneNamingNoFieldIs409() async throws {
        let vm = try await liveAgent()
        try await ask(vm, bash)

        let (notText, _) = try await harness.post("/v1/agents/permission",
                                                  body(["request": "req-1", "answer": "allow", "input": ["command": 3]]))
        let (withDeny, _) = try await harness.post("/v1/agents/permission",
                                                   body(["request": "req-1", "answer": "deny", "input": ["command": "x"]]))
        let (noField, _) = try await harness.post("/v1/agents/permission",
                                                  body(["request": "req-1", "answer": "allow", "input": ["nothing": "x"]]))

        XCTAssertEqual(notText, 400)
        XCTAssertEqual(withDeny, 400)
        XCTAssertEqual(noField, 409)
        XCTAssertEqual(vm.openPromptCount, 1, "the card still waits")
        XCTAssertTrue(runtime.controlLines.isEmpty, "and the session heard nothing")
    }

    func testAlwaysRemembersTheFirstOfferUnlessAnotherIsNamed() async throws {
        let vm = try await liveAgent()
        try await ask(vm, bash)

        let (refused, _) = try await harness.post("/v1/agents/permission", body(["request": "req-1", "answer": "always", "always": 4]))
        XCTAssertEqual(refused, 409, "the card offers nothing at that position")
        XCTAssertEqual(vm.openPromptCount, 1, "and still waits")

        let (status, _) = try await harness.post("/v1/agents/permission", body(["request": "req-1", "answer": "always"]))
        XCTAssertEqual(status, 200)
        XCTAssertEqual((answered("req-1")?["updatedPermissions"] as? [[String: Any]])?.first?["type"] as? String, "addRules")
    }

    func testDenyRefusesTheCallAndASecondAnswerIs409() async throws {
        let vm = try await liveAgent()
        try await ask(vm, bash)

        let (status, _) = try await harness.post("/v1/agents/permission", body(["request": "req-1", "answer": "deny"]))
        XCTAssertEqual(status, 200)
        XCTAssertEqual(answered("req-1")?["behavior"] as? String, "deny")

        let (again, _) = try await harness.post("/v1/agents/permission", body(["request": "req-1", "answer": "allow"]))
        XCTAssertEqual(again, 409)
        XCTAssertEqual(runtime.controlLines.count, 1, "the session heard one answer")
    }

    func testAnAnswerThatIsNotOneOfTheThreeIs400() async throws {
        let vm = try await liveAgent()
        try await ask(vm, bash)

        let (status, _) = try await harness.post("/v1/agents/permission", body(["request": "req-1", "answer": "maybe"]))
        let (missing, _) = try await harness.post("/v1/agents/permission", body(["answer": "allow"]))

        XCTAssertEqual(status, 400)
        XCTAssertEqual(missing, 400)
        XCTAssertTrue(runtime.controlLines.isEmpty)
    }

    // MARK: - Choices

    func testTheModelsQuestionsAreAnsweredOneEach() async throws {
        let vm = try await liveAgent()
        let input = #"{"questions":[{"question":"Tea or coffee?","header":"Drink","multiSelect":false,"options":[{"label":"Tea","description":""}]}]}"#
        try await ask(vm, PermissionPrompt.Request(id: "req-q", toolName: "AskUserQuestion", input: input, needsAnswer: true))

        let (short, _) = try await harness.post("/v1/agents/choices", body(["request": "req-q", "answers": [String]()]))
        XCTAssertEqual(short, 409, "no answer for the question asked")
        let (bad, _) = try await harness.post("/v1/agents/choices", body(["request": "req-q"]))
        XCTAssertEqual(bad, 400)

        let (status, _) = try await harness.post("/v1/agents/choices", body(["request": "req-q", "answers": ["Tea"]]))
        XCTAssertEqual(status, 200)
        XCTAssertEqual((answered("req-q")?["updatedInput"] as? [String: Any])?["answers"] as? [String: String], ["Tea or coffee?": "Tea"])
    }

    // MARK: - Mode

    func testSettingTheModeMovesTheRunningSession() async throws {
        let vm = try await liveAgent()

        let (status, answer) = try await harness.post("/v1/agents/mode", body(["mode": "Accept Edits"]))

        XCTAssertEqual(status, 200)
        XCTAssertEqual(answer["mode"] as? String, "acceptEdits", "the stored spelling comes back, whatever was typed")
        XCTAssertEqual(vm.agentPermissionMode, "acceptEdits")
        XCTAssertTrue(runtime.controlLines.contains { $0.contains("set_permission_mode") && $0.contains("acceptEdits") })

        let (unknown, _) = try await harness.post("/v1/agents/mode", body(["mode": "yolo"]))
        XCTAssertEqual(unknown, 400)
        XCTAssertEqual(vm.agentPermissionMode, "acceptEdits")
    }

    // MARK: - Tasks

    func testRunningTasksAreListedAndOneIsStopped() async throws {
        _ = try await liveAgent(turn: [
            .system(subtype: "task_started", payload: ["task_id": "task-9", "tool_use_id": "toolu_agent", "description": "Run the tests",
                                                       "task_type": "local_agent", "subagent_type": "general-purpose"]),
        ])

        let (_, listed) = try await harness.get("/v1/agents/tasks?project=alpha&agent=Builder")
        let tasks = try XCTUnwrap(listed["tasks"] as? [[String: Any]])
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks.first?["id"] as? String, "task-9")
        XCTAssertEqual(tasks.first?["kind"] as? String, "subagent")
        XCTAssertEqual(tasks.first?["description"] as? String, "Run the tests")
        XCTAssertEqual(tasks.first?["subagent"] as? String, "general-purpose")

        let (gone, _) = try await harness.post("/v1/agents/tasks/stop", body(["task": "task-1"]))
        XCTAssertEqual(gone, 409)
        let (status, _) = try await harness.post("/v1/agents/tasks/stop", body(["task": "task-9"]))
        XCTAssertEqual(status, 200)
        XCTAssertTrue(runtime.controlLines.contains { $0.contains("stop_task") && $0.contains("task-9") })
    }

    func testAnAgentTheProjectDoesNotHaveIs404() async throws {
        _ = try await liveAgent()

        let (permission, _) = try await harness.post("/v1/agents/permission",
                                                      ["project": "alpha", "agent": "Nobody", "request": "r", "answer": "allow"])
        let (tasks, _) = try await harness.get("/v1/agents/tasks?project=alpha&agent=Nobody")

        XCTAssertEqual(permission, 404)
        XCTAssertEqual(tasks, 404)
    }
}
