import XCTest
import KiteloopCore
@testable import Kiteloop

@MainActor
final class ChatViewModelHandoffTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = try makeTemporaryDirectory(prefix: "kiteloop-handoff")
    }

    override func tearDown() async throws {
        ChatViewModel.pendingLaunchNudgeInitialDelay = 60
        ChatViewModel.pendingLaunchNudgeBackoffDelay = 300
    }

    /// A single-node graph whose one node is both entry and terminal — a
    /// worker node needs no schema to exercise `completeActiveWorkflowNode`'s
    /// no-schema branch, same as a real worker.
    private func singleWorkerNodeGraph(agentID: String) -> WorkflowGraph {
        WorkflowGraph(
            id: "pending-agent-test-graph",
            name: "Test",
            version: 1,
            nodes: ["worker": WorkflowNode(id: "worker", agentID: agentID, prompt: "Do the work")],
            edges: [],
            entryNode: "worker",
            terminalNodes: ["worker"],
            metadata: .empty
        )
    }

    func testCustomToolTriggersContinuation() async throws {
        let mock = MockAgentRuntime()
        mock.events = [
            .toolUse(id: "tool-1", name: "publish_event",
                     input: #"{"event":"pr_ready","payload":{"branch":"feature/x"}}"#),
        ]
        mock.toolResultEvents = [
            .assistantText("Done."),
            .result(.init(
                text: "Done.", costUSD: 0.001, durationMs: 100,
                inputTokens: 10, outputTokens: 3,
                cacheCreationInputTokens: 0, cacheReadInputTokens: 0,
                sessionID: "s1", permissionDenials: []
            ))
        ]

        let orchestrator = Orchestrator(runtime: mock)
        let agent = Agent(
            id: "coder", name: "Coder", model: "sonnet",
            systemPrompt: "", tools: [],
            denied: [], permissionMode: "default", state: .idle
        )
        orchestrator.addAgent(agent)
        try await orchestrator.startAgent("coder", cwd: tempDir)

        let vm = ChatViewModel(agentID: "coder", projectURL: tempDir, orchestrator: orchestrator)
        vm.inputText = "Build the feature"
        await vm.send()

        XCTAssertTrue(vm.messages.contains { msg in
            if case .toolCall(let call) = msg.content { return call.name == "publish_event" }
            return false
        })
        XCTAssertTrue(vm.messages.contains { msg in
            if case .text(let t) = msg.content { return t == "Done." }
            return false
        })
    }

    func testAgentTriggeredNotificationAutoSendsTurn() async throws {
        let mock = MockAgentRuntime()
        mock.events = [
            .assistantText("I will review."),
            .result(.init(
                text: "I will review.", costUSD: 0.001, durationMs: 100,
                inputTokens: 5, outputTokens: 4, cacheCreationInputTokens: 0, cacheReadInputTokens: 0, sessionID: "s2", permissionDenials: []
            ))
        ]
        let orchestrator = Orchestrator(runtime: mock)
        let agent = Agent(
            id: "reviewer", name: "Reviewer", model: "sonnet",
            systemPrompt: "", tools: [],
            denied: [], permissionMode: "default", state: .idle
        )
        orchestrator.addAgent(agent)
        try await orchestrator.startAgent("reviewer", cwd: tempDir)

        let vm = ChatViewModel(agentID: "reviewer", projectURL: tempDir, orchestrator: orchestrator)

        // Go through the real entry point: the VM's observer filters on the
        // orchestrator instance, so a bare post(object: nil) never reaches it.
        orchestrator.triggerAgent(agentID: "reviewer", message: "Please review PR #42")

        try await eventually("the triggered message to be auto-sent") {
            await vm.messages.contains { msg in
                if case .human = msg.sender, case .text(let t) = msg.content {
                    return t == "Please review PR #42"
                }
                return false
            }
        }

        XCTAssertFalse(vm.messages.isEmpty, "Expected ChatViewModel to auto-send on agentTriggered")
        XCTAssertTrue(vm.messages.contains { msg in
            if case .human = msg.sender, case .text(let t) = msg.content {
                return t == "Please review PR #42"
            }
            return false
        })
    }

    /// Validates the item's first two acceptance criteria: a turn that ends
    /// with an Agent-tool launch still pending leaves the node open, and the
    /// turn that follows — which makes no new launch of its own, exactly like
    /// a real report, which never names the launch it is closing out —
    /// completes it with that turn's own reply as the closing message, not
    /// the "still waiting" text the launch turn ended on.
    func testPendingBackgroundAgentLaunchDefersHandoffUntilTheNextTurn() async throws {
        let mock = MockAgentRuntime()
        mock.sendEventsQueue = [
            [
                .toolUse(id: "launch-1", name: "Agent", input: "{}"),
                .toolResult(id: "launch-1", output: "Async agent launched successfully. It will run in the background."),
                .result(.init(
                    text: "Launched a background agent to explore this. I'm waiting for its report.",
                    costUSD: 0.001, durationMs: 100, inputTokens: 10, outputTokens: 5,
                    cacheCreationInputTokens: 0, cacheReadInputTokens: 0,
                    sessionID: "s1", permissionDenials: []
                )),
            ],
            [
                .assistantText("The exploration turned up the cause; the fix is in place."),
                .result(.init(
                    text: "The exploration turned up the cause; the fix is in place.",
                    costUSD: 0.001, durationMs: 100, inputTokens: 10, outputTokens: 5,
                    cacheCreationInputTokens: 0, cacheReadInputTokens: 0,
                    sessionID: "s1", permissionDenials: []
                )),
            ],
        ]

        let orchestrator = Orchestrator(runtime: mock)
        let agent = Agent(
            id: "coder", name: "Coder", model: "sonnet",
            systemPrompt: "", tools: [],
            denied: [], permissionMode: "default", state: .idle
        )
        orchestrator.addAgent(agent)
        try await orchestrator.startAgent("coder", cwd: tempDir)
        let execID = try await orchestrator.startWorkflow(graph: singleWorkerNodeGraph(agentID: "coder"), initialState: [:])

        let vm = ChatViewModel(agentID: "coder", projectURL: tempDir, orchestrator: orchestrator)

        vm.inputText = "Investigate and fix the bug"
        await vm.send()

        var execution = await orchestrator.workflowEngine.execution(id: execID)
        XCTAssertEqual(execution?.status, .running, "A pending launch must leave the node open")
        XCTAssertEqual(execution?.currentNode, "worker")
        XCTAssertEqual(orchestrator.pendingBackgroundAgentCount(for: "coder"), 1)

        vm.inputText = "continue"
        await vm.send()

        // `completeActiveWorkflowNode` hands the event to the workflow engine on
        // a detached Task (`Orchestrator.handleWorkflowEvent`), so the execution
        // reflects it a beat after `send()` returns, not synchronously with it.
        try await eventually("the report turn to complete the node") {
            await orchestrator.workflowEngine.execution(id: execID)?.status == .completed
        }
        execution = await orchestrator.workflowEngine.execution(id: execID)
        XCTAssertEqual(orchestrator.pendingBackgroundAgentCount(for: "coder"), 0)
        let closing = execution?.steps.last { $0.nodeID == "worker" }?.output?[RunClosingMessage.outputKey]?.stringValue
        XCTAssertEqual(closing, "The exploration turned up the cause; the fix is in place.")
    }

    /// The production defaults an operator actually waits on
    /// (`a-pending-background-agents-report-is-asked-for-not-waited-on`'s
    /// "within ninety seconds"). The behavioral tests below override these to
    /// run fast, so this is the one place the shipped numbers are pinned.
    func testPendingLaunchNudgeDefaultsMatchTheDocumentedBound() {
        XCTAssertEqual(ChatViewModel.pendingLaunchNudgeInitialDelay, 60)
        XCTAssertLessThanOrEqual(ChatViewModel.pendingLaunchNudgeInitialDelay, 90)
        XCTAssertEqual(ChatViewModel.pendingLaunchNudgeBackoffDelay, 300)
    }

    /// Validates the item's first two acceptance criteria end to end: nobody
    /// sends the worker anything after its launch turn — the automatic nudge
    /// is what gives it another turn — and once that turn ends with nothing
    /// pending, it reaches the hand-off exactly as a normal turn does, using
    /// the nudge reply as the closing message.
    func testPendingLaunchIsNudgedAutomaticallyAndReachesHandoff() async throws {
        ChatViewModel.pendingLaunchNudgeInitialDelay = 0.05
        ChatViewModel.pendingLaunchNudgeBackoffDelay = 0.05

        let mock = MockAgentRuntime()
        mock.sendEventsQueue = [
            [
                .toolUse(id: "launch-1", name: "Agent", input: "{}"),
                .toolResult(id: "launch-1", output: "Async agent launched successfully. It will run in the background."),
                .result(.init(
                    text: "Launched a background agent to explore this. I'm waiting for its report.",
                    costUSD: 0.001, durationMs: 100, inputTokens: 10, outputTokens: 5,
                    cacheCreationInputTokens: 0, cacheReadInputTokens: 0,
                    sessionID: "s1", permissionDenials: []
                )),
            ],
        ]
        mock.events = [
            .assistantText("The exploration turned up the cause; the fix is in place."),
            .result(.init(
                text: "The exploration turned up the cause; the fix is in place.",
                costUSD: 0.001, durationMs: 100, inputTokens: 10, outputTokens: 5,
                cacheCreationInputTokens: 0, cacheReadInputTokens: 0,
                sessionID: "s1", permissionDenials: []
            )),
        ]

        let orchestrator = Orchestrator(runtime: mock)
        let agent = Agent(
            id: "coder", name: "Coder", model: "sonnet",
            systemPrompt: "", tools: [],
            denied: [], permissionMode: "default", state: .idle
        )
        orchestrator.addAgent(agent)
        try await orchestrator.startAgent("coder", cwd: tempDir)
        let execID = try await orchestrator.startWorkflow(graph: singleWorkerNodeGraph(agentID: "coder"), initialState: [:])

        let vm = ChatViewModel(agentID: "coder", projectURL: tempDir, orchestrator: orchestrator)
        vm.inputText = "Investigate and fix the bug"
        await vm.send()

        var execution = await orchestrator.workflowEngine.execution(id: execID)
        XCTAssertEqual(execution?.status, .running, "A pending launch must leave the node open")
        XCTAssertEqual(orchestrator.pendingBackgroundAgentCount(for: "coder"), 1)

        try await eventually(timeout: .seconds(5), "the automatic nudge to reach hand-off") {
            await orchestrator.workflowEngine.execution(id: execID)?.status == .completed
        }
        XCTAssertEqual(mock.lastSentMessage,
                       "The background agent you launched is still running. Wait for its report, then continue the item.",
                       "the nudge, not a human, must be what gave the session its next turn")
        execution = await orchestrator.workflowEngine.execution(id: execID)
        XCTAssertEqual(orchestrator.pendingBackgroundAgentCount(for: "coder"), 0)
        let closing = execution?.steps.last { $0.nodeID == "worker" }?.output?[RunClosingMessage.outputKey]?.stringValue
        XCTAssertEqual(closing, "The exploration turned up the cause; the fix is in place.")
    }

    /// Validates the item's third acceptance criterion: a nudge the session
    /// answers with literally nothing must not be read as the report. The
    /// stall watchdog reads `pendingBackgroundAgentCount` and the node's
    /// status to decide whether to end the run — this is the guarantee it
    /// depends on, that a silent nudge leaves both exactly as it found them
    /// rather than completing the node on an empty reply.
    func testASilentNudgeLeavesThePendingCountAndNodeUntouched() async throws {
        ChatViewModel.pendingLaunchNudgeInitialDelay = 0.05
        ChatViewModel.pendingLaunchNudgeBackoffDelay = 60

        let mock = MockAgentRuntime()
        mock.sendEventsQueue = [
            [
                .toolUse(id: "launch-1", name: "Agent", input: "{}"),
                .toolResult(id: "launch-1", output: "Async agent launched successfully. It will run in the background."),
                .result(.init(
                    text: "Launched a background agent to explore this. I'm waiting for its report.",
                    costUSD: 0.001, durationMs: 100, inputTokens: 10, outputTokens: 5,
                    cacheCreationInputTokens: 0, cacheReadInputTokens: 0,
                    sessionID: "s1", permissionDenials: []
                )),
            ],
        ]
        mock.events = []   // every later send() — the nudge — answers nothing at all

        let orchestrator = Orchestrator(runtime: mock)
        let agent = Agent(
            id: "coder", name: "Coder", model: "sonnet",
            systemPrompt: "", tools: [],
            denied: [], permissionMode: "default", state: .idle
        )
        orchestrator.addAgent(agent)
        try await orchestrator.startAgent("coder", cwd: tempDir)
        let execID = try await orchestrator.startWorkflow(graph: singleWorkerNodeGraph(agentID: "coder"), initialState: [:])

        let vm = ChatViewModel(agentID: "coder", projectURL: tempDir, orchestrator: orchestrator)
        vm.inputText = "Investigate and fix the bug"
        await vm.send()

        XCTAssertEqual(orchestrator.pendingBackgroundAgentCount(for: "coder"), 1)

        try await eventually(timeout: .seconds(5), "the automatic nudge to have gone out") {
            mock.lastSentMessage == "The background agent you launched is still running. Wait for its report, then continue the item."
        }

        // The silent nudge's own turn has already run to completion by the
        // time `lastSentMessage` observably changed (both happen on the same
        // `@MainActor` turn), so the state it leaves behind is stable to
        // assert on directly rather than needing a further wait.
        let execution = await orchestrator.workflowEngine.execution(id: execID)
        XCTAssertEqual(execution?.status, .running, "a silent nudge must not be read as the report")
        XCTAssertEqual(orchestrator.pendingBackgroundAgentCount(for: "coder"), 1,
                       "the original launch is still unaccounted for — the stall watchdog must still see it")
    }

    /// Validates the item's fourth acceptance criterion: the real incidents'
    /// shape — a launch, then nothing — replayed through a scripted runtime
    /// that eventually does answer a nudge ends in a hand-off, not a stall.
    /// The first nudge lands on silence (as the original transcripts show);
    /// the backoff nudge that follows is what finally gets a reply.
    func testLaunchThenSilenceThenAReportEndsInHandoffNotAbandonment() async throws {
        ChatViewModel.pendingLaunchNudgeInitialDelay = 0.05
        ChatViewModel.pendingLaunchNudgeBackoffDelay = 0.05

        let mock = MockAgentRuntime()
        mock.sendEventsQueue = [
            [
                .toolUse(id: "launch-1", name: "Agent", input: "{}"),
                .toolResult(id: "launch-1", output: "Async agent launched successfully. It will run in the background."),
                .result(.init(
                    text: "Launched a background agent to explore this. I'm waiting for its report.",
                    costUSD: 0.001, durationMs: 100, inputTokens: 10, outputTokens: 5,
                    cacheCreationInputTokens: 0, cacheReadInputTokens: 0,
                    sessionID: "s1", permissionDenials: []
                )),
            ],
            [],   // the first nudge — silence, matching the real transcripts
        ]
        mock.events = [   // the backoff nudge that follows — the report finally lands
            .assistantText("The exploration turned up the cause; the fix is in place."),
            .result(.init(
                text: "The exploration turned up the cause; the fix is in place.",
                costUSD: 0.001, durationMs: 100, inputTokens: 10, outputTokens: 5,
                cacheCreationInputTokens: 0, cacheReadInputTokens: 0,
                sessionID: "s1", permissionDenials: []
            )),
        ]

        let orchestrator = Orchestrator(runtime: mock)
        let agent = Agent(
            id: "coder", name: "Coder", model: "sonnet",
            systemPrompt: "", tools: [],
            denied: [], permissionMode: "default", state: .idle
        )
        orchestrator.addAgent(agent)
        try await orchestrator.startAgent("coder", cwd: tempDir)
        let execID = try await orchestrator.startWorkflow(graph: singleWorkerNodeGraph(agentID: "coder"), initialState: [:])

        let vm = ChatViewModel(agentID: "coder", projectURL: tempDir, orchestrator: orchestrator)
        vm.inputText = "Investigate and fix the bug"
        await vm.send()

        try await eventually(timeout: .seconds(5), "the replayed shape to end in a hand-off") {
            await orchestrator.workflowEngine.execution(id: execID)?.status == .completed
        }
        let execution = await orchestrator.workflowEngine.execution(id: execID)
        XCTAssertEqual(orchestrator.pendingBackgroundAgentCount(for: "coder"), 0)
        let closing = execution?.steps.last { $0.nodeID == "worker" }?.output?[RunClosingMessage.outputKey]?.stringValue
        XCTAssertEqual(closing, "The exploration turned up the cause; the fix is in place.")
    }

    /// Validates the item's second acceptance criterion: a turn with no Agent
    /// launch at all is unaffected by the guard — the node completes on the
    /// very first turn, same as before this item.
    func testNoAgentLaunchCompletesNodeOnFirstTurn() async throws {
        let mock = MockAgentRuntime()
        mock.events = [
            .assistantText("Done — fixed it directly."),
            .result(.init(
                text: "Done — fixed it directly.", costUSD: 0.001, durationMs: 100,
                inputTokens: 10, outputTokens: 5, cacheCreationInputTokens: 0, cacheReadInputTokens: 0,
                sessionID: "s1", permissionDenials: []
            )),
        ]

        let orchestrator = Orchestrator(runtime: mock)
        let agent = Agent(
            id: "coder", name: "Coder", model: "sonnet",
            systemPrompt: "", tools: [],
            denied: [], permissionMode: "default", state: .idle
        )
        orchestrator.addAgent(agent)
        try await orchestrator.startAgent("coder", cwd: tempDir)
        let execID = try await orchestrator.startWorkflow(graph: singleWorkerNodeGraph(agentID: "coder"), initialState: [:])

        let vm = ChatViewModel(agentID: "coder", projectURL: tempDir, orchestrator: orchestrator)
        vm.inputText = "Fix the bug"
        await vm.send()

        try await eventually("the turn to complete the node") {
            await orchestrator.workflowEngine.execution(id: execID)?.status == .completed
        }
        XCTAssertEqual(orchestrator.pendingBackgroundAgentCount(for: "coder"), 0)
    }

    func testReceiveHandoffPrefillsInputText() {
        let mock = MockAgentRuntime()
        let orchestrator = Orchestrator(runtime: mock)
        let agent = Agent(
            id: "reviewer", name: "Reviewer", model: "sonnet",
            systemPrompt: "", tools: [],
            denied: [], permissionMode: "default", state: .idle
        )
        orchestrator.addAgent(agent)
        let vm = ChatViewModel(agentID: "reviewer", projectURL: tempDir, orchestrator: orchestrator)

        vm.receiveHandoff("Review PR #99 — branch: feature/auth", from: "coder")

        XCTAssertEqual(vm.inputText, "Review PR #99 — branch: feature/auth")
        XCTAssertFalse(vm.messages.isEmpty, "Should inject a system message noting the handoff origin")
        if let first = vm.messages.first {
            XCTAssertEqual(first.sender, .system)
        }
    }

    private func namedTeamViewModel() -> ChatViewModel {
        let orchestrator = Orchestrator(runtime: MockAgentRuntime())
        for (id, name) in [("backend-dev", "API Lead"), ("qa", "QA")] {
            orchestrator.addAgent(Agent(
                id: id, name: name, model: "sonnet",
                systemPrompt: "", tools: [],
                denied: [], permissionMode: "default", state: .idle
            ))
        }
        return ChatViewModel(agentID: "qa", projectURL: tempDir, orchestrator: orchestrator)
    }

    func testDisplayNameIsTheNameTheAgentWasGivenNotItsID() {
        XCTAssertEqual(namedTeamViewModel().displayName(forAgentID: "backend-dev"), "API Lead")
    }

    func testDisplayNameKeepsCapitalsInsideAWord() {
        XCTAssertEqual(namedTeamViewModel().displayName(forAgentID: "qa"), "QA")
    }

    func testDisplayNameOfAnIDNoAgentHasIsTheCapitalizedID() {
        XCTAssertEqual(namedTeamViewModel().displayName(forAgentID: "guest-reviewer"), "Guest-Reviewer")
    }

    func testReceiveHandoffNamesTheSenderByTheNameItWasGiven() {
        let vm = namedTeamViewModel()

        vm.receiveHandoff("Check the endpoint", from: "backend-dev")

        guard case .text(let divider)? = vm.messages.first?.content else {
            return XCTFail("Expected a text divider noting the handoff origin")
        }
        XCTAssertEqual(divider, "↩ Forwarded from API Lead")
    }
}
