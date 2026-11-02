import XCTest
import KiteloopCore
@testable import Kiteloop

/// Steering an agent from the phone: stopping its turn, answering its plan
/// card and answering the question it stopped to ask — each through the same
/// view-model call the Mac's own button makes. Driven over a real loopback
/// socket against a scripted runtime.
@MainActor
final class KiteloopControlServerAgentSteeringTests: XCTestCase {

    private var tempDir: URL!
    private var registry: ControlSessionRegistry!
    private var harness: ControlServerHarness!
    private var runtime: MockAgentRuntime!

    override func setUp() async throws {
        tempDir = try makeTemporaryDirectory(prefix: "control-agent-steering")
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

    // MARK: - Stop

    func testInterruptingAWorkingAgentEndsItsTurn() async throws {
        let session = try registerProject(named: "alpha")
        let agentID = addAgent(named: "Builder", to: session)
        runtime.startDelay = 5_000_000_000
        runtime.events = [.result(Self.done("late"))]
        _ = try await harness.post("/v1/agents/message", ["project": "alpha", "agent": "Builder", "message": "go"])
        let vm = try XCTUnwrap(session.chatViewModels[agentID])
        try await eventually("the turn is running") { vm.isStreaming }

        let (status, body) = try await harness.post("/v1/agents/interrupt", ["project": "alpha", "agent": "Builder"])

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["interrupted"] as? Bool, true)
        XCTAssertEqual(runtime.interruptCount, 1, "the stop reached the runtime")
    }

    func testInterruptingAnIdleAgentChangesNothing() async throws {
        let session = try registerProject(named: "alpha")
        addAgent(named: "Builder", to: session)

        let (status, body) = try await harness.post("/v1/agents/interrupt", ["project": "alpha", "agent": "Builder"])

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["interrupted"] as? Bool, false)
        XCTAssertEqual(runtime.interruptCount, 0)
    }

    func testInterruptWithoutAnAgentIs400() async throws {
        try registerProject(named: "alpha")
        let (status, _) = try await harness.post("/v1/agents/interrupt", ["project": "alpha"])
        XCTAssertEqual(status, 400)
    }

    // MARK: - Plan cards

    /// A Plan-mode agent's turn that wrote a plan, ended on its card.
    private func plannedTurn() async throws -> (ChatViewModel, UUID) {
        let session = try registerProject(named: "alpha")
        let agentID = addAgent(named: "Planner", to: session, permissionMode: "plan")
        let path = PlanProposalDetector.userPlansDirectory.appending(path: "x.md").path
        let input = try JSONSerialization.data(withJSONObject: ["file_path": path, "content": "# Plan\n\n1. Build it"])
        runtime.events = [
            .toolUse(id: "write-1", name: "Write", input: String(decoding: input, as: UTF8.self)),
            .toolResult(id: "write-1", output: "File created successfully"),
            .assistantText("The plan is written."),
            .result(Self.done("The plan is written.")),
        ]
        _ = try await harness.post("/v1/agents/message",
                                   ["project": "alpha", "agent": "Planner", "message": "plan it", "wait": true],
                                   timeout: 30)
        let vm = try XCTUnwrap(session.chatViewModels[agentID])
        let card = try XCTUnwrap(vm.messages.first { if case .plan = $0.content { return true }; return false })
        runtime.events = [.result(Self.done("Built."))]
        return (vm, card.id)
    }

    func testThePlanReachesTheTranscriptAsAnOpenCard() async throws {
        let (_, cardID) = try await plannedTurn()

        let (_, body) = try await harness.get("/v1/agents/transcript?project=alpha&agent=Planner")

        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let plan = try XCTUnwrap(messages.first { $0["id"] as? String == cardID.uuidString })
        XCTAssertEqual(plan["kind"] as? String, "plan")
        XCTAssertEqual((plan["plan"] as? [String: Any])?["open"] as? Bool, true)
    }

    func testApprovingThePlanFromTheAPISwitchesTheModeAndBuilds() async throws {
        let (vm, cardID) = try await plannedTurn()

        let (status, _) = try await harness.post(
            "/v1/agents/plan",
            ["project": "alpha", "agent": "Planner", "message": cardID.uuidString, "answer": "approveAuto"])

        XCTAssertEqual(status, 200)
        try await eventually("the card is answered") {
            vm.messages.contains {
                if case .plan(let plan) = $0.content { return plan.answer == .approveAuto }
                return false
            }
        }
        try await eventually("the approval was sent as the Mac's card sends it") {
            self.runtime.sentMessages.contains { $0.message == ChatViewModel.planApprovalMessage }
        }
    }

    func testAnsweringAPlanTwiceIs409() async throws {
        let (vm, cardID) = try await plannedTurn()
        let body: [String: Any] = ["project": "alpha", "agent": "Planner", "message": cardID.uuidString, "answer": "keepPlanning"]
        _ = try await harness.post("/v1/agents/plan", body)
        try await eventually("the first answer landed") {
            vm.messages.contains { if case .plan(let plan) = $0.content { return plan.answer != nil }; return false }
        }

        let (status, _) = try await harness.post("/v1/agents/plan", body)

        XCTAssertEqual(status, 409)
    }

    func testAnUnknownPlanAnswerIs400() async throws {
        let (_, cardID) = try await plannedTurn()

        let (status, _) = try await harness.post(
            "/v1/agents/plan", ["project": "alpha", "agent": "Planner", "message": cardID.uuidString, "answer": "yes"])

        XCTAssertEqual(status, 400)
    }

    // MARK: - Questions

    private func askedTurn() async throws -> ChatViewModel {
        let session = try registerProject(named: "alpha")
        let agentID = addAgent(named: "Builder", to: session)
        runtime.events = [
            .toolUse(id: "ask-1", name: "ask_human", input: "{\"question\": \"Keep the old rounding?\"}"),
            .result(Self.done("waiting")),
        ]
        runtime.toolResultEvents = [.result(Self.done("thanks"))]
        _ = try await harness.post("/v1/agents/message",
                                   ["project": "alpha", "agent": "Builder", "message": "fix it", "wait": true],
                                   timeout: 30)
        let vm = try XCTUnwrap(session.chatViewModels[agentID])
        XCTAssertEqual(vm.pendingHumanToolCallID, "ask-1")
        return vm
    }

    func testTheQuestionReachesTheTranscriptWithItsRequest() async throws {
        _ = try await askedTurn()

        let (_, body) = try await harness.get("/v1/agents/transcript?project=alpha&agent=Builder")

        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let question = try XCTUnwrap(messages.first { $0["kind"] as? String == "question" })
        XCTAssertEqual(question["text"] as? String, "Keep the old rounding?")
        XCTAssertEqual((question["question"] as? [String: Any])?["request"] as? String, "ask-1")
    }

    func testAnsweringTheQuestionResumesTheTurn() async throws {
        let vm = try await askedTurn()

        let (status, _) = try await harness.post(
            "/v1/agents/answer", ["project": "alpha", "agent": "Builder", "request": "ask-1", "answer": "Keep it"])

        XCTAssertEqual(status, 200)
        try await eventually("the answer reached the paused turn") {
            self.runtime.toolResultsSent.contains { $0.toolCallID == "ask-1" && $0.content == "Keep it" }
        }
        XCTAssertNil(vm.pendingHumanToolCallID)
    }

    func testAQuestionTheAgentIsNotWaitingOnIs409() async throws {
        _ = try await askedTurn()

        let (status, _) = try await harness.post(
            "/v1/agents/answer", ["project": "alpha", "agent": "Builder", "request": "ask-0", "answer": "Keep it"])

        XCTAssertEqual(status, 409)
        XCTAssertTrue(runtime.toolResultsSent.isEmpty, "nothing was sent to the agent")
    }

    func testABlankAnswerIs400() async throws {
        _ = try await askedTurn()

        let (status, _) = try await harness.post(
            "/v1/agents/answer", ["project": "alpha", "agent": "Builder", "request": "ask-1", "answer": "  "])

        XCTAssertEqual(status, 400)
    }

    // MARK: - Helpers

    private static func done(_ text: String) -> StreamEvent.ResultPayload {
        .init(text: text, costUSD: 0.01, durationMs: 500, inputTokens: 100, outputTokens: 50,
              cacheCreationInputTokens: 0, cacheReadInputTokens: 0, sessionID: "s1", permissionDenials: [])
    }

    @discardableResult
    private func registerProject(named name: String) throws -> ProjectSession {
        let root = tempDir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let rootURL = URL(fileURLWithPath: root.path(percentEncoded: false), isDirectory: false)
        let project = KiteloopProject(rootURL: rootURL)
        try project.ensureDirectoryExists()

        let eventBus = EventBus(eventsURL: project.eventsURL)
        let orchestrator = Orchestrator(
            runtime: runtime,
            eventBus: eventBus,
            subscriptionEngine: SubscriptionEngine(eventBus: eventBus),
            memoryManager: MemoryManager(project: project)
        )
        let session = ProjectSession(
            project: project,
            projectURL: rootURL,
            orchestrator: orchestrator,
            sessionStore: SessionStore(projectDir: rootURL),
            knowledgeStore: AgentKnowledgeStore(baseURL: project.knowledgeURL),
            knowledgeIndex: KnowledgeIndex(baseURL: project.knowledgeURL),
            context: makeContext()
        )
        registry.register(session: session, autopilot: BacklogAutopilot())
        return session
    }

    @discardableResult
    private func addAgent(named name: String, to projectSession: ProjectSession,
                          permissionMode: String = "acceptEdits") -> String {
        let agent = Agent(name: name, model: "sonnet", systemPrompt: "", tools: [], denied: [],
                          permissionMode: permissionMode)
        projectSession.orchestrator.addAgent(agent)
        return agent.id
    }

    private func makeContext() -> ProjectSessionContext {
        ProjectSessionContext(
            runtimeFactory: { [runtime] in runtime! },
            agentCatalogStore: AgentCatalogStore(storageURL: tempDir.appendingPathComponent("catalog.json")),
            packageResolver: nil,
            globalConfigStore: GlobalConfigStore(storageURL: tempDir.appendingPathComponent("global.json")),
            orgManifestLoader: OrgManifestLoader(),
            repoCloneService: RepoCloneService()
        )
    }
}
