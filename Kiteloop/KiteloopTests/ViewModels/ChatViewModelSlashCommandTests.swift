import XCTest
import KiteloopCore
@testable import Kiteloop

@MainActor
final class ChatViewModelSlashCommandTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = try makeTemporaryDirectory(prefix: "kiteloop-slash")
    }

    // MARK: - Helpers

    private func makeVM(events: [StreamEvent] = []) async throws -> (ChatViewModel, MockAgentRuntime) {
        let (vm, mock, _) = try await makeVMOverOrchestrator(events: events)
        return (vm, mock)
    }

    /// The same view model, with the orchestrator behind it — the only place a
    /// test can read what a command wrote onto the agent, or install a hook.
    private func makeVMOverOrchestrator(
        events: [StreamEvent] = []
    ) async throws -> (ChatViewModel, MockAgentRuntime, Orchestrator) {
        let mock = MockAgentRuntime()
        mock.events = events
        let orchestrator = Orchestrator(runtime: mock)
        let agent = Agent(
            id: "test-agent", name: "TestAgent", model: "sonnet",
            systemPrompt: "", tools: [],
            denied: [], permissionMode: "default", state: .idle
        )
        orchestrator.addAgent(agent)
        try await orchestrator.startAgent("test-agent", cwd: tempDir)
        let vm = ChatViewModel(agentID: "test-agent", projectURL: tempDir, orchestrator: orchestrator)
        // A suite of the test's own, never the app's defaults: a measured
        // window is written there and read back by the next session.
        vm.contextWindowDefaults = UserDefaults(suiteName: "ChatViewModelSlashCommandTests.\(UUID().uuidString)") ?? .standard
        return (vm, mock, orchestrator)
    }

    private func testAgent(in orchestrator: Orchestrator) -> Agent? {
        orchestrator.agents.first { $0.id == "test-agent" }
    }

    // MARK: - /clear

    func testSlashClearRemovesMessages() async throws {
        let (vm, _) = try await makeVM()

        // Pre-populate some messages so there is something to clear.
        vm.inputText = "Hello"
        // Inject a human message directly without going through the runtime.
        // We need a runtime result to avoid the "process died" branch, so use a minimal result.
        let mock = MockAgentRuntime()
        mock.events = [
            .assistantText("Hi there"),
            .result(.init(
                text: "Hi there", costUSD: 0.001, durationMs: 50,
                inputTokens: 5, outputTokens: 3,
                cacheCreationInputTokens: 0, cacheReadInputTokens: 0,
                sessionID: "s1", permissionDenials: []
            ))
        ]
        let orchestrator2 = Orchestrator(runtime: mock)
        let agent2 = Agent(
            id: "clear-agent", name: "ClearAgent", model: "sonnet",
            systemPrompt: "", tools: [],
            denied: [], permissionMode: "default", state: .idle
        )
        orchestrator2.addAgent(agent2)
        try await orchestrator2.startAgent("clear-agent", cwd: tempDir)
        let vm2 = ChatViewModel(agentID: "clear-agent", projectURL: tempDir, orchestrator: orchestrator2)

        // Send a real message so messages is non-empty.
        vm2.inputText = "Hello"
        await vm2.send()
        XCTAssertFalse(vm2.messages.isEmpty, "Pre-condition: messages should be non-empty before /clear")

        // Now issue /clear.
        vm2.inputText = "/clear"
        await vm2.send()

        XCTAssertTrue(vm2.messages.isEmpty, "/clear should empty the messages array")
        XCTAssertEqual(vm2.inputText, "", "/clear should clear inputText")
    }

    /// A turn whose result frame reports cache tokens, opened by an init frame
    /// that gives the window size so /context can say a percentage.
    private func cachedTurnEvents(input: Int, cacheRead: Int, cacheCreation: Int) -> [StreamEvent] {
        [
            .system(subtype: "init", payload: ["context_window_size": 200_000]),
            .assistantText("ok"),
            .result(.init(
                text: "ok", costUSD: 0.05, durationMs: 1200,
                inputTokens: input, outputTokens: 40,
                cacheCreationInputTokens: cacheCreation, cacheReadInputTokens: cacheRead,
                sessionID: "s-cache", permissionDenials: []
            ))
        ]
    }

    private func lastSystemText(_ vm: ChatViewModel) -> String? {
        guard case .text(let t) = vm.messages.last(where: { $0.sender == .system })?.content else { return nil }
        return t
    }

    /// /context straight after a clear used to add the cleared session's cache
    /// counters to the fresh session's zero input and report the old fill.
    func testSlashClearThenContextReportsAnEmptyWindow() async throws {
        let (vm, _) = try await makeVM(events: cachedTurnEvents(input: 100, cacheRead: 50_000, cacheCreation: 30_000))
        vm.inputText = "Hello"
        await vm.send()

        vm.inputText = "/clear"
        await vm.send()
        vm.inputText = "/context"
        await vm.send()

        let text = try XCTUnwrap(lastSystemText(vm))
        XCTAssertTrue(text.contains("**Context window:** 0% used"), text)
        XCTAssertFalse(text.contains("Cache"), text)
    }

    func testSlashClearThenCostReportsAFreshSession() async throws {
        let (vm, _) = try await makeVM(events: cachedTurnEvents(input: 100, cacheRead: 50_000, cacheCreation: 30_000))
        vm.inputText = "Hello"
        await vm.send()

        vm.inputText = "/clear"
        await vm.send()
        vm.inputText = "/cost"
        await vm.send()

        let text = try XCTUnwrap(lastSystemText(vm))
        XCTAssertTrue(text.contains("$0.0000"), text)
        XCTAssertTrue(text.contains("Last turn: 0 in / 0 out (0ms)"), text)
        XCTAssertFalse(text.contains("Cache"), text)
    }

    func testATurnAfterClearSetsTheCountersFromItsOwnResult() async throws {
        let (vm, mock) = try await makeVM()
        mock.sendEventsQueue = [
            cachedTurnEvents(input: 100, cacheRead: 50_000, cacheCreation: 30_000),
            cachedTurnEvents(input: 2_000, cacheRead: 0, cacheCreation: 18_000)
        ]
        vm.inputText = "Hello"
        await vm.send()
        vm.inputText = "/clear"
        await vm.send()
        vm.inputText = "Again"
        await vm.send()

        vm.inputText = "/context"
        await vm.send()

        let text = try XCTUnwrap(lastSystemText(vm))
        XCTAssertTrue(text.contains("**Context window:** 10% used"), text)
        XCTAssertTrue(text.contains("**Cache:** 0 read, 18000 created"), text)
    }

    func testSlashContextOnAnOllamaAgentReportsTokensAndNoPercentage() async throws {
        let (vm, _, orchestrator) = try await makeVMOverOrchestrator(
            events: cachedTurnEvents(input: 1_200, cacheRead: 0, cacheCreation: 0))
        orchestrator.updateAgent(id: "test-agent") { $0.model = "llama3.1"; $0.runtimeKind = "ollama" }
        vm.inputText = "Hello"
        await vm.send()

        XCTAssertNil(vm.contextWindowSize, "An Ollama model's window is not Claude's")

        vm.inputText = "/context"
        await vm.send()

        let text = try XCTUnwrap(lastSystemText(vm))
        XCTAssertTrue(text.contains("Input: 1200 tokens, Output: 40 tokens"), text)
        XCTAssertTrue(text.contains("not known"), text)
        XCTAssertFalse(text.contains("% used"), text)
        XCTAssertFalse(text.contains("unknown"), text)
    }

    func testAWindowFromAClaudeSessionIsNotReusedAfterSwitchingToOllama() async throws {
        let (vm, _, orchestrator) = try await makeVMOverOrchestrator(
            events: cachedTurnEvents(input: 100, cacheRead: 0, cacheCreation: 0))
        vm.inputText = "Hello"
        await vm.send()
        XCTAssertEqual(vm.contextWindowSize, 200_000)

        orchestrator.updateAgent(id: "test-agent") { $0.model = "llama3.1"; $0.runtimeKind = "ollama" }

        XCTAssertNil(vm.contextWindowSize)
    }

    /// A current CLI's init frame names the model and no window; the turn's
    /// result measures it. /context used to read 100k tokens of a 1M window
    /// against a guessed 200k and say 50%.
    func testTheWindowATurnsResultMeasuredIsWhatContextReadsAgainst() async throws {
        var result = StreamEvent.ResultPayload(
            text: "ok", costUSD: 0.05, durationMs: 1200, inputTokens: 100_000, outputTokens: 40,
            cacheCreationInputTokens: 0, cacheReadInputTokens: 0, sessionID: "s-1m", permissionDenials: [])
        result.contextWindows = ["claude-opus-5-5": 1_000_000, "claude-haiku-5-5": 200_000]
        let (vm, _) = try await makeVM(events: [
            .system(subtype: "init", payload: ["model": "claude-opus-5-5"]),
            .assistantText("ok"),
            .result(result)
        ])
        vm.inputText = "Hello"
        await vm.send()
        XCTAssertEqual(vm.contextWindowSize, 1_000_000)

        vm.inputText = "/context"
        await vm.send()
        let text = try XCTUnwrap(lastSystemText(vm))
        XCTAssertTrue(text.contains("**Context window:** 10% used"), text)
    }

    /// A model measured once opens its next session — a relaunch's resume —
    /// with that window, before any turn reports one.
    func testAWindowMeasuredBeforeIsShownWhenTheNextSessionOpens() async throws {
        let suite = "ChatViewModelWindow.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(1_000_000, forKey: ChatViewModel.contextWindowKey(for: "claude-opus-5-5"))
        let (vm, _) = try await makeVM(events: [
            .system(subtype: "init", payload: ["model": "claude-opus-5-5"]),
            .assistantText("ok"),
            .result(.init(text: "ok", costUSD: 0, durationMs: 1, inputTokens: 1, outputTokens: 1,
                          cacheCreationInputTokens: 0, cacheReadInputTokens: 0, sessionID: "s-known",
                          permissionDenials: []))
        ])
        vm.contextWindowDefaults = defaults
        vm.inputText = "Hello"
        await vm.send()
        XCTAssertEqual(vm.contextWindowSize, 1_000_000)
    }

    func testAMeasuredWindowIsKeptForTheModel() async throws {
        let suite = "ChatViewModelWindow.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var result = StreamEvent.ResultPayload(
            text: "ok", costUSD: 0, durationMs: 1, inputTokens: 1, outputTokens: 1,
            cacheCreationInputTokens: 0, cacheReadInputTokens: 0, sessionID: "s-keep", permissionDenials: [])
        result.contextWindows = ["claude-opus-5-5": 1_000_000]
        let (vm, _) = try await makeVM(events: [
            .system(subtype: "init", payload: ["model": "claude-opus-5-5"]), .assistantText("ok"), .result(result)
        ])
        vm.contextWindowDefaults = defaults
        vm.inputText = "Hello"
        await vm.send()
        XCTAssertEqual(defaults.integer(forKey: ChatViewModel.contextWindowKey(for: "claude-opus-5-5")), 1_000_000)
    }

    func testAWindowNothingMeasuredIsUnknownNotGuessed() async throws {
        let (vm, _) = try await makeVM(events: [
            .system(subtype: "init", payload: ["model": "claude-opus-5-5"]),
            .assistantText("ok"),
            .result(.init(
                text: "ok", costUSD: 0.05, durationMs: 1200, inputTokens: 100, outputTokens: 40,
                cacheCreationInputTokens: 0, cacheReadInputTokens: 0, sessionID: "s-none", permissionDenials: []))
        ])
        vm.inputText = "Hello"
        await vm.send()

        XCTAssertNil(vm.contextWindowSize)
    }

    // MARK: - /cost

    func testSlashCostAddsSystemMessage() async throws {
        // First send a real message to populate cost fields via the result event.
        let mock = MockAgentRuntime()
        mock.events = [
            .assistantText("Done."),
            .result(.init(
                text: "Done.", costUSD: 0.05, durationMs: 1200,
                inputTokens: 100, outputTokens: 40,
                cacheCreationInputTokens: 10, cacheReadInputTokens: 20,
                sessionID: "s-cost", permissionDenials: []
            ))
        ]
        let orchestrator = Orchestrator(runtime: mock)
        let agent = Agent(
            id: "cost-agent", name: "CostAgent", model: "sonnet",
            systemPrompt: "", tools: [],
            denied: [], permissionMode: "default", state: .idle
        )
        orchestrator.addAgent(agent)
        try await orchestrator.startAgent("cost-agent", cwd: tempDir)
        let vm = ChatViewModel(agentID: "cost-agent", projectURL: tempDir, orchestrator: orchestrator)

        vm.inputText = "Do something"
        await vm.send()

        // Now send /cost.
        vm.inputText = "/cost"
        await vm.send()

        XCTAssertEqual(vm.inputText, "", "/cost should clear inputText")

        let systemMessages = vm.messages.filter { $0.sender == .system }
        XCTAssertFalse(systemMessages.isEmpty, "Expected at least one system message after /cost")

        let costMsg = systemMessages.last
        XCTAssertNotNil(costMsg, "Expected a cost system message")
        if case .text(let t) = costMsg?.content {
            XCTAssertTrue(t.contains("Session Cost"), "Cost message should contain 'Session Cost'")
            XCTAssertTrue(t.contains("0.0500"), "Cost message should contain formatted cost value")
        } else {
            XCTFail("Expected .text content in cost message, got \(String(describing: costMsg?.content))")
        }
    }

    func testSlashCostOnAnOllamaAgentSaysItIsLocalAndShowsTokens() async throws {
        let (vm, _, orchestrator) = try await makeVMOverOrchestrator(
            events: cachedTurnEvents(input: 1_200, cacheRead: 0, cacheCreation: 0))
        orchestrator.updateAgent(id: "test-agent") { $0.model = "llama3.1"; $0.runtimeKind = "ollama" }
        vm.inputText = "Hello"
        await vm.send()

        vm.inputText = "/cost"
        await vm.send()

        let text = try XCTUnwrap(lastSystemText(vm))
        XCTAssertTrue(text.contains("locally"), text)
        XCTAssertTrue(text.contains("nothing is charged"), text)
        XCTAssertTrue(text.contains("1200 in / 40 out"), text)
        XCTAssertFalse(text.contains("$"), text)
    }

    func testSlashCostOnACopilotAgentSaysTheBridgeReportsNoTokensOrCost() async throws {
        let (vm, _) = makeNonClaudeVM(model: "copilot")

        vm.inputText = "/cost"
        await vm.send()

        let text = try XCTUnwrap(lastSystemText(vm))
        XCTAssertTrue(text.contains("Copilot bridge reports neither tokens nor cost"), text)
        XCTAssertFalse(text.contains("$0.0000"), text)
        XCTAssertFalse(text.contains("0 in / 0 out"), text)
    }

    // MARK: - /model

    func testSlashModelSwitchesModel() async throws {
        let (vm, _) = try await makeVM()

        vm.inputText = "/model opus"
        await vm.send()

        XCTAssertEqual(vm.inputText, "", "/model should clear inputText")

        let systemMessages = vm.messages.filter { $0.sender == .system }
        XCTAssertFalse(systemMessages.isEmpty, "Expected a system message after /model switch")

        // The confirmation message should mention the new model name.
        let hasConfirmation = systemMessages.contains { msg in
            if case .text(let t) = msg.content {
                return t.contains("opus")
            }
            return false
        }
        XCTAssertTrue(hasConfirmation, "Expected a system message confirming the model switch to 'opus'")

        // The agent's model should have been updated.
        XCTAssertEqual(vm.agentModel, "opus", "Agent model should be updated to 'opus'")
    }

    func testSlashModelWithAnUnknownNameRefusesAndKeepsTheModel() async throws {
        let (vm, mock, orchestrator) = try await makeVMOverOrchestrator()
        mock.lastSessionOptions = nil

        vm.inputText = "/model sonet"
        await vm.send()

        XCTAssertEqual(testAgent(in: orchestrator)?.model, "sonnet")
        XCTAssertTrue(messages(vm, containing: "Unknown model: **sonet**"))
        XCTAssertTrue(messages(vm, containing: "opus, sonnet, fable, haiku"))
        for other in ["llama3.1", "qwen2.5-coder", "copilot"] {
            XCTAssertFalse(messages(vm, containing: other), "\(other) is not a model a Claude agent can run")
        }
        XCTAssertFalse(messages(vm, containing: "Switched to"))
        XCTAssertNil(mock.lastSessionOptions, "An unknown model must not restart the agent")
        XCTAssertNil(mock.lastSentMessage, "An unknown model must not reach the runtime as a prompt")
        XCTAssertEqual(vm.inputText, "")
    }

    func testSlashModelInAnotherCaseStoresTheCatalogID() async throws {
        let (vm, _, orchestrator) = try await makeVMOverOrchestrator()

        vm.inputText = "/model Opus"
        await vm.send()

        XCTAssertEqual(testAgent(in: orchestrator)?.model, "opus")
        XCTAssertTrue(messages(vm, containing: "Switched to model: **opus**"))
    }

    func testSlashModelWithAPinnedClaudeIDStoresItAsTyped() async throws {
        let (vm, _, orchestrator) = try await makeVMOverOrchestrator()

        vm.inputText = "/model claude-opus-4-6"
        await vm.send()

        XCTAssertEqual(testAgent(in: orchestrator)?.model, "claude-opus-4-6")
        XCTAssertTrue(messages(vm, containing: "Switched to model: **claude-opus-4-6**"))
    }

    func testSlashModelOnAnOllamaAgentAcceptsAnyTag() async throws {
        let (vm, orchestrator) = makeNonClaudeVM(model: "llama3.1")

        vm.inputText = "/model mistral"
        await vm.send()

        XCTAssertEqual(orchestrator.agents.first { $0.id == "other-agent" }?.model, "mistral")
        XCTAssertTrue(messages(vm, containing: "Switched to model: **mistral**"))
    }

    func testSlashModelOnAnOllamaAgentRefusesAClaudeModel() async throws {
        let (vm, mock, orchestrator) = try await makeVMOverOrchestrator()
        orchestrator.updateAgent(id: "test-agent") { $0.model = "llama3.1"; $0.runtimeKind = "ollama" }
        mock.lastSessionOptions = nil

        vm.inputText = "/model opus"
        await vm.send()

        XCTAssertEqual(testAgent(in: orchestrator)?.model, "llama3.1")
        XCTAssertTrue(messages(vm, containing: "Claude"))
        XCTAssertTrue(messages(vm, containing: "Ollama"))
        XCTAssertFalse(messages(vm, containing: "Switched to"))
        XCTAssertNil(mock.lastSessionOptions, "A refused model must not restart the agent")
    }

    func testSlashModelOnAClaudeAgentRefusesAnOllamaOrCopilotModel() async throws {
        for typed in ["llama3.1", "copilot"] {
            let (vm, mock, orchestrator) = try await makeVMOverOrchestrator()
            mock.lastSessionOptions = nil

            vm.inputText = "/model \(typed)"
            await vm.send()

            XCTAssertEqual(testAgent(in: orchestrator)?.model, "sonnet", typed)
            XCTAssertFalse(messages(vm, containing: "Switched to"), typed)
            XCTAssertNil(mock.lastSessionOptions, "/model \(typed) must not restart a Claude agent")
        }
    }

    func testSlashModelOnAnInferredOllamaAgentKeepsItOnOllama() async throws {
        let (vm, orchestrator) = makeNonClaudeVM(model: "llama3.1")

        vm.inputText = "/model gemma2"
        await vm.send()

        let agent = orchestrator.agents.first { $0.id == "other-agent" }
        XCTAssertEqual(agent?.model, "gemma2")
        XCTAssertEqual(agent?.resolvedRuntimeKind, .ollama)
    }

    // MARK: - /effort (invalid)

    func testSlashEffortRejectsInvalidLevel() async throws {
        let (vm, _) = try await makeVM()

        vm.inputText = "/effort banana"
        await vm.send()

        XCTAssertEqual(vm.inputText, "", "/effort with invalid level should still clear inputText")

        let systemMessages = vm.messages.filter { $0.sender == .system }
        XCTAssertFalse(systemMessages.isEmpty, "Expected an error system message for invalid effort level")

        let hasValidLevelsHint = systemMessages.contains { msg in
            if case .text(let t) = msg.content {
                return t.contains("low") && t.contains("high")
            }
            return false
        }
        XCTAssertTrue(hasValidLevelsHint, "Error message should list valid effort levels")
    }

    // MARK: - /effort (valid)

    func testSlashEffortSetsValidLevel() async throws {
        let (vm, _) = try await makeVM()

        vm.inputText = "/effort high"
        await vm.send()

        XCTAssertEqual(vm.inputText, "", "/effort with valid level should clear inputText")

        let systemMessages = vm.messages.filter { $0.sender == .system }
        XCTAssertFalse(systemMessages.isEmpty, "Expected a confirmation system message for valid effort level")

        let hasConfirmation = systemMessages.contains { msg in
            if case .text(let t) = msg.content {
                return t.contains("high")
            }
            return false
        }
        XCTAssertTrue(hasConfirmation, "Confirmation message should mention the effort level 'high'")
    }

    // MARK: - command case

    /// Autocapitalisation turns `/clear` into `/Clear`; it must still run the
    /// command rather than go to the agent as a prompt.
    func testSlashClearInCapitalsClearsAndSendsNothing() async throws {
        let (vm, mock) = try await makeVM(events: replyEvents(sessionID: "s-capital-clear"))
        vm.inputText = "Hello"
        await vm.send()

        vm.inputText = "/Clear"
        await vm.send()

        XCTAssertTrue(vm.messages.isEmpty, "/Clear should empty the messages array")
        XCTAssertEqual(mock.sentMessages.map(\.message), ["Hello"], "/Clear must not reach the runtime as a prompt")
    }

    func testSlashEffortInCapitalsStoresTheLowercaseLevel() async throws {
        let (vm, _, orchestrator) = try await makeVMOverOrchestrator()

        vm.inputText = "/EFFORT High"
        await vm.send()

        XCTAssertEqual(testAgent(in: orchestrator)?.effort, "high")
        XCTAssertFalse(messages(vm, containing: "Valid effort levels"))
    }

    func testSlashThinkingOffInCapitalsDisablesThinkingAndClearsTheBudget() async throws {
        let (vm, _, orchestrator) = try await makeVMOverOrchestrator()
        vm.inputText = "/thinking 8000"
        await vm.send()

        vm.inputText = "/thinking OFF"
        await vm.send()

        XCTAssertEqual(testAgent(in: orchestrator)?.thinkingEnabled, false)
        XCTAssertNil(testAgent(in: orchestrator)?.thinkingBudget)
        XCTAssertTrue(messages(vm, containing: "Extended thinking disabled."))
    }

    func testSlashGoalKeepsTheCapitalsOfItsCondition() async throws {
        let (vm, mock) = try await makeVM(events: [
            .assistantText("Done.\nGOAL_COMPLETE"),
            .result(.init(
                text: "Done.\nGOAL_COMPLETE", costUSD: 0.002, durationMs: 10,
                inputTokens: 2, outputTokens: 2,
                cacheCreationInputTokens: 0, cacheReadInputTokens: 0,
                sessionID: "s-goal-caps", permissionDenials: []
            ))
        ])

        vm.inputText = "/Goal Ship The Release"
        await vm.send()

        XCTAssertTrue(messages(vm, containing: "Goal set: **Ship The Release**"))
        XCTAssertTrue(mock.lastSentMessage?.contains("**Goal:** Ship The Release") == true)
    }

    func testSlashGoalsInCapitalsSetsNoGoalAndReachesTheAgentAsTyped() async throws {
        let (vm, mock) = try await makeVM(events: replyEvents(sessionID: "s-capital-goals"))

        vm.inputText = "/Goals"
        await vm.send()

        XCTAssertNil(vm.activeGoal)
        XCTAssertEqual(mock.lastSentMessage, "/Goals")
    }

    // MARK: - bare /model and /effort

    /// Bare `/model` used to miss the `"/model "` arm once `send()` trimmed it,
    /// and went to the agent as a prompt. It answers from the chat instead.
    func testBareSlashModelReportsTheCurrentModelWithoutSendingOrRestarting() async throws {
        let (vm, mock, orchestrator) = try await makeVMOverOrchestrator()
        mock.lastSessionOptions = nil

        vm.inputText = "/model"
        await vm.send()

        let systemMessages = vm.messages.filter { $0.sender == .system }
        XCTAssertEqual(systemMessages.count, 1, "Bare /model should post exactly one system message")
        XCTAssertTrue(messages(vm, containing: ModelCatalog.displayName(for: "sonnet")),
                      "The reply should name the agent's model by its display name")
        XCTAssertTrue(messages(vm, containing: "/model <name>"), "The reply should say how to switch")
        XCTAssertNil(mock.lastSentMessage, "Bare /model must not reach the runtime as a prompt")
        XCTAssertNil(mock.lastSessionOptions, "Bare /model must not restart the agent")
        XCTAssertEqual(testAgent(in: orchestrator)?.model, "sonnet")
        XCTAssertEqual(vm.inputText, "")
    }

    func testBareSlashEffortReportsTheCurrentEffortAndTheLevelsWithoutSendingOrRestarting() async throws {
        let (vm, mock, orchestrator) = try await makeVMOverOrchestrator()
        mock.lastSessionOptions = nil

        vm.inputText = "/effort"
        await vm.send()

        let systemMessages = vm.messages.filter { $0.sender == .system }
        XCTAssertEqual(systemMessages.count, 1, "Bare /effort should post exactly one system message")
        XCTAssertTrue(messages(vm, containing: SettingNames.effort("")),
                      "The reply should name the agent's current effort")
        XCTAssertTrue(messages(vm, containing: "low, medium, high, xhigh, max"),
                      "The reply should list every valid level")
        XCTAssertNil(mock.lastSentMessage, "Bare /effort must not reach the runtime as a prompt")
        XCTAssertNil(mock.lastSessionOptions, "Bare /effort must not restart the agent")
        XCTAssertNil(testAgent(in: orchestrator)?.effort)
        XCTAssertEqual(testAgent(in: orchestrator)?.model, "sonnet")
        XCTAssertEqual(vm.inputText, "")
    }

    // MARK: - /mode

    func testBareSlashModeReportsThePickerNameAndTheChoicesWithoutRestarting() async throws {
        let (vm, mock, orchestrator) = try await makeVMOverOrchestrator()
        orchestrator.updateAgent(id: "test-agent") { $0.permissionMode = "acceptEdits" }
        mock.lastSessionOptions = nil

        vm.inputText = "/mode"
        await vm.send()

        XCTAssertEqual(vm.messages.filter { $0.sender == .system }.count, 1)
        XCTAssertTrue(messages(vm, containing: "**Permission mode:** Accept Edits"))
        XCTAssertTrue(messages(vm, containing: "auto, acceptEdits, plan, default, dontAsk, bypassPermissions"))
        XCTAssertNil(mock.lastSentMessage, "Bare /mode must not reach the runtime as a prompt")
        XCTAssertNil(mock.lastSessionOptions, "Bare /mode must not restart the agent")
        XCTAssertEqual(testAgent(in: orchestrator)?.permissionMode, "acceptEdits")
        XCTAssertEqual(vm.inputText, "")
    }

    /// A running session takes the new mode as it is: one line on its control
    /// channel, the same process, nothing restarted — between two modes that
    /// both ask.
    func testSlashModePlanOnAnAskingAgentMovesItsRunningSessionToPlan() async throws {
        let (vm, mock, orchestrator) = try await makeVMOverOrchestrator(events: replyEvents(sessionID: "s-mode"))
        orchestrator.updateAgent(id: "test-agent") { $0.permissionMode = "acceptEdits" }
        vm.inputText = "hello"
        await vm.send()
        mock.lastStartedAgent = nil

        vm.inputText = "/mode plan"
        await vm.send()

        XCTAssertEqual(testAgent(in: orchestrator)?.permissionMode, "plan")
        XCTAssertNil(mock.lastStartedAgent, "a running session is not restarted to change its mode")
        XCTAssertEqual(mock.controlLines.count, 1)
        let line = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(mock.controlLines[0].utf8)) as? [String: Any])
        XCTAssertEqual((line["request"] as? [String: Any])?["subtype"] as? String, "set_permission_mode")
        XCTAssertEqual((line["request"] as? [String: Any])?["mode"] as? String, "plan")
        XCTAssertTrue(messages(vm, containing: "Permission mode set to: **Plan (read-only)**"))
        XCTAssertEqual(mock.sentMessages.count, 1, "/mode must not reach the runtime as a prompt")
    }

    /// A session spawned in Auto has its agent's tools approved, which no line
    /// on its control channel takes back: moving it to a mode that asks takes
    /// a new process, on the same conversation, spawned to ask.
    func testSlashModePlanOnAnAutoAgentRestartsItToAskOnTheSameSession() async throws {
        let (vm, mock, orchestrator) = try await makeVMOverOrchestrator(events: replyEvents(sessionID: "s-mode"))
        orchestrator.stopAgent("test-agent")
        orchestrator.updateAgent(id: "test-agent") { $0.permissionMode = "auto" }
        try await orchestrator.startAgent("test-agent", cwd: tempDir)
        XCTAssertEqual(mock.lastSessionOptions?.asksBeforeListedTools, false, "Auto keeps the agent's tools approved")
        vm.inputText = "hello"
        await vm.send()
        mock.lastStartedAgent = nil
        mock.lastStrategy = nil

        vm.inputText = "/mode plan"
        await vm.send()

        XCTAssertEqual(testAgent(in: orchestrator)?.permissionMode, "plan")
        XCTAssertTrue(mock.controlLines.isEmpty, "the running session cannot be told to start asking")
        XCTAssertNotNil(mock.lastStartedAgent, "so it is replaced")
        XCTAssertEqual(mock.lastSessionOptions?.asksBeforeListedTools, true)
        guard case .resume(let sessionID) = mock.lastStrategy else {
            return XCTFail("The restart should resume the session, not start fresh")
        }
        XCTAssertEqual(sessionID, "s-mode")
    }

    /// An agent with no session running is started in the new mode on the
    /// session the last turn left behind, so the spawn carries the new flag
    /// and the same conversation.
    func testSlashModePlanOnAStoppedAgentStartsItInPlanOnTheSameSession() async throws {
        let (vm, mock, orchestrator) = try await makeVMOverOrchestrator(events: replyEvents(sessionID: "s-mode"))
        orchestrator.updateAgent(id: "test-agent") { $0.permissionMode = "auto" }
        vm.inputText = "hello"
        await vm.send()
        orchestrator.stopAgent("test-agent")
        mock.lastStartedAgent = nil
        mock.lastStrategy = nil

        vm.inputText = "/mode plan"
        await vm.send()

        XCTAssertEqual(testAgent(in: orchestrator)?.permissionMode, "plan")
        XCTAssertTrue(mock.controlLines.isEmpty, "there is no session to tell")
        let spawned = try XCTUnwrap(mock.lastStartedAgent, "/mode <name> should restart the agent")
        XCTAssertEqual(Array(ClaudeCodeCLIRuntime.permissionArguments(agent: spawned, unattended: false).prefix(2)),
                       ["--permission-mode", "plan"])
        guard case .resume(let sessionID) = mock.lastStrategy else {
            return XCTFail("The restart should resume the session, not start fresh")
        }
        XCTAssertEqual(sessionID, "s-mode")
        XCTAssertTrue(messages(vm, containing: "Permission mode set to: **Plan (read-only)**"))
        XCTAssertEqual(mock.sentMessages.count, 1, "/mode must not reach the runtime as a prompt")
    }

    func testSlashModeTakesThePickerNameInAnyCaseAndSpacing() async throws {
        for typed in ["/mode Accept Edits", "/mode ACCEPTEDITS", "/mode bypass all"] {
            let (vm, _, orchestrator) = try await makeVMOverOrchestrator()

            vm.inputText = typed
            await vm.send()

            let expected = typed.hasSuffix("all") ? "bypassPermissions" : "acceptEdits"
            XCTAssertEqual(testAgent(in: orchestrator)?.permissionMode, expected, typed)
        }
    }

    func testSlashModeWithAnUnknownNameRefusesAndLeavesTheAgentAsItWas() async throws {
        let (vm, mock, orchestrator) = try await makeVMOverOrchestrator(events: replyEvents(sessionID: "s-keep"))
        vm.inputText = "hello"
        await vm.send()
        mock.lastSessionOptions = nil

        vm.inputText = "/mode nonsense"
        await vm.send()

        XCTAssertEqual(testAgent(in: orchestrator)?.permissionMode, "default")
        XCTAssertTrue(messages(vm, containing: "Unknown permission mode: **nonsense**"))
        XCTAssertTrue(messages(vm, containing: "auto, acceptEdits, plan, default, dontAsk, bypassPermissions"))
        XCTAssertNil(mock.lastSessionOptions, "An unknown mode must not restart the agent")
        XCTAssertEqual(KiteloopProject(rootURL: tempDir).loadConfig().agentSessionIDs?["TestAgent"], "s-keep")
        XCTAssertEqual(mock.sentMessages.count, 1, "An unknown mode must not reach the runtime as a prompt")
    }

    func testSlashModeOnAnOllamaAgentSaysItIsClaudeOnlyAndChangesNothing() async throws {
        let (vm, mock, orchestrator) = try await makeVMOverOrchestrator()
        orchestrator.updateAgent(id: "test-agent") { $0.model = "llama3.1"; $0.runtimeKind = "ollama" }
        mock.lastSessionOptions = nil

        for typed in ["/mode", "/mode plan"] {
            vm.inputText = typed
            await vm.send()
        }

        XCTAssertTrue(messages(vm, containing: "/mode applies to Claude agents only"))
        XCTAssertEqual(testAgent(in: orchestrator)?.permissionMode, "default")
        XCTAssertNil(mock.lastSessionOptions, "/mode must not restart an Ollama agent")
        XCTAssertNil(mock.lastSentMessage)
    }

    // MARK: - /branch

    private func messages(_ vm: ChatViewModel, containing substring: String) -> Bool {
        vm.messages.contains { msg in
            if case .text(let t) = msg.content { return t.contains(substring) }
            return false
        }
    }

    private func makeReplyingVM() async throws -> ChatViewModel {
        let (vm, _) = try await makeVM(events: [
            .assistantText("ack"),
            .result(.init(
                text: "ack", costUSD: 0.001, durationMs: 10,
                inputTokens: 1, outputTokens: 1,
                cacheCreationInputTokens: 0, cacheReadInputTokens: 0,
                sessionID: "s-branch", permissionDenials: []
            ))
        ])
        return vm
    }

    /// Messages added while on a branch survive `/branch main` and are there
    /// again on `/branch switch <name>` back — the tree used to hand back the
    /// creation-time snapshot instead of what was actually said on it.
    func testSlashBranchRoundTripPreservesBranchMessages() async throws {
        let vm = try await makeReplyingVM()

        vm.inputText = "main message 1"
        await vm.send()

        vm.inputText = "/branch mybranch"
        await vm.send()

        vm.inputText = "/branch switch mybranch"
        await vm.send()

        vm.inputText = "branch message"
        await vm.send()
        XCTAssertTrue(messages(vm, containing: "branch message"))

        vm.inputText = "/branch main"
        await vm.send()
        XCTAssertFalse(messages(vm, containing: "branch message"), "/branch main should not show the branch's messages")

        vm.inputText = "/branch switch mybranch"
        await vm.send()
        XCTAssertTrue(messages(vm, containing: "branch message"), "switching back should restore what was said on the branch")
    }

    /// `/branch main` restores the main transcript as it stood when the branch
    /// was entered, not the branch's messages relabelled as main.
    func testSlashBranchMainRestoresMainTranscriptNotBranchs() async throws {
        let vm = try await makeReplyingVM()

        vm.inputText = "main message 1"
        await vm.send()
        XCTAssertTrue(messages(vm, containing: "main message 1"))

        vm.inputText = "/branch mybranch"
        await vm.send()

        vm.inputText = "/branch switch mybranch"
        await vm.send()
        XCTAssertTrue(messages(vm, containing: "Switched to branch **mybranch**. This changed only what the chat shows"),
                      "/branch switch should say it changed only the chat")

        vm.inputText = "branch-only message"
        await vm.send()

        vm.inputText = "/branch main"
        await vm.send()

        XCTAssertTrue(messages(vm, containing: "main message 1"), "/branch main should restore main's own transcript")
        XCTAssertFalse(messages(vm, containing: "branch-only message"), "/branch main must not show the branch's messages")
        XCTAssertTrue(messages(vm, containing: "Switched to main branch. This changed only what the chat shows"),
                      "/branch main should say it changed only the chat")
        XCTAssertTrue(messages(vm, containing: "`/clear`"), "a branch switch should name /clear as the way to start fresh")
    }

    /// A taken name is refused, naming it — it used to make a second branch
    /// of the same name that `/branch switch` and `/branch delete` never reach.
    func testSlashBranchRefusesATakenName() async throws {
        let vm = try await makeReplyingVM()
        vm.inputText = "main message 1"
        await vm.send()

        vm.inputText = "/branch x"
        await vm.send()
        vm.inputText = "/branch x"
        await vm.send()

        XCTAssertEqual(vm.conversationTree.branches.filter { $0.name == "x" }.count, 1)
        XCTAssertTrue(messages(vm, containing: "A branch named **x** already exists"))
    }

    /// The default name skips one in use: after branch-1 is deleted, a bare
    /// `/branch` used to make a second branch-2.
    func testBareSlashBranchPicksANameNotInUse() async throws {
        let vm = try await makeReplyingVM()
        vm.inputText = "main message 1"
        await vm.send()

        for command in ["/branch", "/branch", "/branch delete branch-1"] {
            vm.inputText = command
            await vm.send()
        }
        let before = Set(vm.conversationTree.branches.map(\.name))
        XCTAssertEqual(before, ["branch-2"])

        vm.inputText = "/branch"
        await vm.send()

        let names = vm.conversationTree.branches.map(\.name)
        XCTAssertEqual(names.count, 2)
        XCTAssertEqual(Set(names).count, 2, "the new default name must not be one already in use")
    }

    /// Creating a branch does not switch onto it, and the reply says so.
    func testSlashBranchFromMainSaysYouAreStillOnMain() async throws {
        let vm = try await makeReplyingVM()
        vm.inputText = "main message 1"
        await vm.send()

        vm.inputText = "/branch x"
        await vm.send()

        XCTAssertNil(vm.conversationTree.activeBranchID)
        XCTAssertTrue(messages(vm, containing: "You are still on **main**"))
        XCTAssertTrue(messages(vm, containing: "`/branch switch x`"))
        XCTAssertFalse(messages(vm, containing: "Continue chatting on this branch"))
    }

    /// A bare `/branch switch` or `/branch delete` says how to use it; each
    /// used to save a branch named after the keyword.
    func testSlashBranchSwitchOrDeleteWithNoNameGivesUsage() async throws {
        let vm = try await makeReplyingVM()
        vm.inputText = "main message 1"
        await vm.send()

        for action in ["switch", "delete"] {
            let before = vm.conversationTree.branches.map(\.name)
            vm.inputText = "/branch \(action)"
            await vm.send()

            XCTAssertEqual(vm.conversationTree.branches.map(\.name), before, "/branch \(action) must not make a branch")
            XCTAssertTrue(messages(vm, containing: "Usage: /branch \(action) <name>"))
        }
        XCTAssertFalse(messages(vm, containing: "Saved branch"))
    }

    /// `Switch` is read as `switch`; the name after it is found in any case,
    /// and the branch keeps the case it was made with.
    func testSlashBranchSwitchKeywordInAnyCaseAndNameKeepsItsCase() async throws {
        let vm = try await makeReplyingVM()
        vm.inputText = "main message 1"
        await vm.send()

        for command in ["/branch Fix", "/branch other", "/branch Switch fix"] {
            vm.inputText = command
            await vm.send()
        }
        XCTAssertEqual(vm.conversationTree.activeBranch?.name, "Fix")
        XCTAssertFalse(vm.conversationTree.branches.contains { $0.name == "Switch fix" })
        XCTAssertFalse(vm.conversationTree.branches.contains { $0.name == "fix" })
    }

    /// Deleting the branch you are on puts the chat back on main, and says so.
    func testSlashBranchDeleteOfTheActiveBranchSaysYouAreBackOnMain() async throws {
        let vm = try await makeReplyingVM()
        vm.inputText = "main message 1"
        await vm.send()

        for command in ["/branch x", "/branch switch x"] {
            vm.inputText = command
            await vm.send()
        }
        vm.inputText = "branch-only message"
        await vm.send()

        vm.inputText = "/branch delete x"
        await vm.send()

        XCTAssertNil(vm.conversationTree.activeBranchID)
        XCTAssertEqual(Array(vm.messages.dropLast()).map(\.id), vm.conversationTree.mainMessages.map(\.id))
        XCTAssertTrue(messages(vm, containing: "Deleted branch **x**. You are back on **main**."))
        XCTAssertFalse(messages(vm, containing: "branch-only message"))
    }

    /// `/branch switch main`, in any case, does what `/branch main` does; it
    /// used to answer that there was no branch named main.
    func testSlashBranchSwitchMainGoesToTheMainLine() async throws {
        for command in ["/branch switch main", "/branch switch MAIN"] {
            let vm = try await makeReplyingVM()
            vm.inputText = "main message 1"
            await vm.send()
            for step in ["/branch x", "/branch switch x", "branch-only message", command] {
                vm.inputText = step
                await vm.send()
            }

            XCTAssertNil(vm.conversationTree.activeBranchID, command)
            XCTAssertTrue(messages(vm, containing: "main message 1"), command)
            XCTAssertFalse(messages(vm, containing: "branch-only message"), command)
            XCTAssertTrue(messages(vm, containing: "Switched to main branch. This changed only what the chat shows"), command)
            XCTAssertFalse(messages(vm, containing: "No branch named"), command)
        }
    }

    /// `/branch delete main` refuses and leaves the branches and transcript alone.
    func testSlashBranchDeleteMainIsRefused() async throws {
        let vm = try await makeReplyingVM()
        vm.inputText = "main message 1"
        await vm.send()
        for command in ["/branch x", "/branch switch x"] {
            vm.inputText = command
            await vm.send()
        }
        let branches = vm.conversationTree.branches.map(\.id)
        let active = vm.conversationTree.activeBranchID
        let before = vm.messages.map(\.id)

        vm.inputText = "/branch delete main"
        await vm.send()

        XCTAssertTrue(messages(vm, containing: "The main line cannot be deleted."))
        XCTAssertEqual(vm.conversationTree.branches.map(\.id), branches)
        XCTAssertEqual(vm.conversationTree.activeBranchID, active)
        XCTAssertEqual(Array(vm.messages.dropLast()).map(\.id), before)
    }

    /// Deleting another branch leaves the transcript as it was.
    func testSlashBranchDeleteOfAnotherBranchLeavesTheTranscript() async throws {
        let vm = try await makeReplyingVM()
        vm.inputText = "main message 1"
        await vm.send()
        vm.inputText = "/branch x"
        await vm.send()
        let before = vm.messages.map(\.id)

        vm.inputText = "/branch delete x"
        await vm.send()

        XCTAssertEqual(Array(vm.messages.dropLast()).map(\.id), before)
        XCTAssertTrue(messages(vm, containing: "Deleted branch **x**."))
        XCTAssertFalse(messages(vm, containing: "back on **main**"))
    }

    func testSlashBranchFromABranchNamesThatBranchAsTheLineYouAreOn() async throws {
        let vm = try await makeReplyingVM()
        vm.inputText = "main message 1"
        await vm.send()

        for command in ["/branch x", "/branch switch x", "/branch y"] {
            vm.inputText = command
            await vm.send()
        }

        XCTAssertEqual(vm.conversationTree.activeBranch?.name, "x")
        XCTAssertTrue(messages(vm, containing: "You are still on **x**"))
    }

    // MARK: - A slash that names nothing

    private func replyEvents(sessionID: String) -> [StreamEvent] {
        [
            .assistantText("ack"),
            .result(.init(
                text: "ack", costUSD: 0.001, durationMs: 10,
                inputTokens: 1, outputTokens: 1,
                cacheCreationInputTokens: 0, cacheReadInputTokens: 0,
                sessionID: sessionID, permissionDenials: []
            ))
        ]
    }

    /// A bare `/` names no skill and no command. It used to trap: the skill
    /// expansion split the text after the slash and read the first part of an
    /// empty split. It goes to the agent as ordinary text.
    func testBareSlashIsSentAsOrdinaryText() async throws {
        let (vm, mock) = try await makeVM(events: replyEvents(sessionID: "s-slash"))

        vm.inputText = "/"
        await vm.send()

        XCTAssertEqual(mock.lastSentMessage, "/", "A bare slash should reach the agent unchanged")
        XCTAssertTrue(messages(vm, containing: "/"), "The bare slash should be in the transcript")
        XCTAssertEqual(vm.inputText, "", "Sending should clear inputText")
    }

    /// The same for a slash followed by nothing but spaces — `send()` trims it
    /// back to a bare `/` before anything else looks at it.
    func testSlashFollowedByOnlySpacesIsSentAsOrdinaryText() async throws {
        let (vm, mock) = try await makeVM(events: replyEvents(sessionID: "s-slash-space"))

        vm.inputText = "/ "
        await vm.send()

        XCTAssertEqual(mock.lastSentMessage, "/", "A slash and spaces should reach the agent as a bare slash")
        XCTAssertEqual(vm.inputText, "", "Sending should clear inputText")
    }

    /// A word that only starts with a command name is not that command: it
    /// falls through to skill expansion and on to the agent unchanged.
    func testSlashGoalsSetsNoGoalAndReachesTheAgent() async throws {
        let (vm, mock) = try await makeVM(events: replyEvents(sessionID: "s-goals"))

        vm.inputText = "/goals"
        await vm.send()

        XCTAssertFalse(messages(vm, containing: "Goal set"), "/goals must not set a goal")
        XCTAssertNil(vm.activeGoal)
        XCTAssertEqual(mock.lastSentMessage, "/goals")
    }

    func testSlashBranchesMakesNoBranchAndReachesTheAgent() async throws {
        let (vm, mock) = try await makeVM(events: replyEvents(sessionID: "s-branches"))
        let before = vm.conversationTree.branches.map(\.name)

        vm.inputText = "/branches"
        await vm.send()

        XCTAssertEqual(vm.conversationTree.branches.map(\.name), before, "/branches must not make a branch")
        XCTAssertEqual(mock.lastSentMessage, "/branches")
    }

    func testSlashLooperStartsNoLoopAndReachesTheAgent() async throws {
        let (vm, mock) = try await makeVM(events: replyEvents(sessionID: "s-looper"))

        vm.inputText = "/looper"
        await vm.send()

        XCTAssertNil(vm.activeGoal, "/looper must not start a loop")
        XCTAssertEqual(mock.lastSentMessage, "/looper")
    }

    func testSlashThinkingDeepChangesNothingAndReachesTheAgent() async throws {
        let (vm, mock) = try await makeVM(events: replyEvents(sessionID: "s-thinking-deep"))

        vm.inputText = "/thinking-deep"
        await vm.send()

        XCTAssertFalse(messages(vm, containing: "Usage: /thinking"), "/thinking-deep must not print the /thinking usage")
        XCTAssertEqual(mock.lastSentMessage, "/thinking-deep")
    }

    // MARK: - /doctor

    private func makeExecutable(named name: String) throws -> String {
        let url = tempDir.appendingPathComponent(name)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path(percentEncoded: false))
        return url.path(percentEncoded: false)
    }

    /// Doesn't go through `ProjectSession.makeChatViewModel` — this drives
    /// `configure(...)` directly so the test controls exactly what
    /// `globalConfigStore` resolves to.
    private func configuredVM(claudePath: String? = nil) async throws -> ChatViewModel {
        let (vm, _) = try await makeVM()
        var config = GlobalConfig()
        config.claudePath = claudePath
        let configURL = tempDir.appendingPathComponent("global-\(UUID().uuidString).json")
        try JSONEncoder().encode(config).write(to: configURL)
        let globalConfigStore = GlobalConfigStore(storageURL: configURL)
        let catalogStore = AgentCatalogStore(storageURL: tempDir.appendingPathComponent("catalog.json"))
        vm.configure(catalogStore: catalogStore, globalConfigStore: globalConfigStore)
        return vm
    }

    private func doctorReport(from vm: ChatViewModel) async -> String {
        vm.inputText = "/doctor"
        await vm.send()
        let systemMessages = vm.messages.filter { $0.sender == .system }
        guard case .text(let text) = systemMessages.last?.content else {
            XCTFail("Expected a text system message after /doctor")
            return ""
        }
        return text
    }

    func testSlashDoctorReportsConfiguredClaudePathInsteadOfNotFound() async throws {
        let path = try makeExecutable(named: "claude")
        let vm = try await configuredVM(claudePath: path)

        let report = await doctorReport(from: vm)

        XCTAssertTrue(report.contains(path), "Expected /doctor to name the configured claudePath override")
        XCTAssertFalse(report.contains("Claude CLI: NOT FOUND"), "A configured, executable override must not report NOT FOUND")
    }

    func testSlashDoctorReportsResolvedNodePathNotJustFound() async throws {
        let vm = try await configuredVM()

        let report = await doctorReport(from: vm)

        XCTAssertFalse(report.contains("Node.js: found"), "Node line should print the resolved path, not the word 'found'")
    }

    func testSlashDoctorWithNothingConfiguredMatchesCLIResolver() async throws {
        let vm = try await configuredVM()
        let expected = CLIResolver.resolve(globalConfig: GlobalConfig())

        let report = await doctorReport(from: vm)

        XCTAssertTrue(report.contains("Claude CLI: \(expected.claude ?? "NOT FOUND")"))
        XCTAssertTrue(report.contains("Node.js: \(expected.node ?? "NOT FOUND")"))
    }

    func testSlashDoctorWithoutConfigureStillProducesReport() async throws {
        let (vm, _) = try await makeVM()

        let report = await doctorReport(from: vm)

        XCTAssertTrue(report.contains("Claude CLI:"))
        XCTAssertTrue(report.contains("Node.js:"))
    }

    func testSlashDoctorOnOllamaAgentReportsOllamaUnreachableWithoutClaudeCLI() async {
        let (vm, _) = makeNonClaudeVM(model: "llama3.1")
        vm.runtimeReachable = { _ in false }

        let report = await doctorReport(from: vm)

        XCTAssertTrue(report.contains("Runtime: Ollama"))
        XCTAssertTrue(report.contains("Ollama: not reachable"))
        XCTAssertFalse(report.contains("Claude CLI:"))
        XCTAssertFalse(report.contains("Node.js:"))
    }

    func testSlashDoctorOnCopilotAgentReportsBridgeReachable() async {
        let (vm, _) = makeNonClaudeVM(model: "copilot")
        var probed: [RuntimeKind] = []
        vm.runtimeReachable = { kind in probed.append(kind); return true }

        let report = await doctorReport(from: vm)

        XCTAssertEqual(probed, [.copilot])
        XCTAssertTrue(report.contains("Runtime: Copilot"))
        XCTAssertTrue(report.contains("Copilot bridge: reachable"))
        XCTAssertFalse(report.contains("Claude CLI:"))
    }

    func testSlashDoctorShowsModelAndPermissionModeDisplayNames() async {
        let orchestrator = Orchestrator(runtime: MockAgentRuntime())
        orchestrator.addAgent(Agent(
            id: "opus-agent", name: "OpusAgent", model: "opus",
            systemPrompt: "", tools: [],
            denied: [], permissionMode: "acceptEdits", state: .idle
        ))
        let vm = ChatViewModel(agentID: "opus-agent", projectURL: tempDir, orchestrator: orchestrator)

        let report = await doctorReport(from: vm)

        XCTAssertTrue(report.contains("Model: Opus"))
        XCTAssertTrue(report.contains("Permission mode: Accept Edits"))
        XCTAssertFalse(report.contains("acceptEdits"))
        XCTAssertTrue(report.contains("Runtime: Claude"))
    }
    // MARK: - /fork and /compact

    /// Both commands resume the Claude session the last turn left behind, so
    /// the turn has to happen first — the session id is written to the project
    /// config when the result frame lands.
    private func vmAfterOneTurn(sessionID: String) async throws -> (ChatViewModel, MockAgentRuntime) {
        let (vm, mock) = try await makeVM(events: replyEvents(sessionID: sessionID))
        vm.inputText = "hello"
        await vm.send()
        return (vm, mock)
    }

    func testSlashForkWithNoSessionYetSaysToSendAMessageFirst() async throws {
        let (vm, _) = try await makeVM()

        vm.inputText = "/fork"
        await vm.send()

        XCTAssertTrue(messages(vm, containing: "No session to fork"), "Expected /fork to say there is nothing to fork from")
        XCTAssertEqual(vm.inputText, "", "/fork should clear inputText")
    }

    func testSlashForkAfterATurnReportsTheForkedSession() async throws {
        let (vm, _) = try await vmAfterOneTurn(sessionID: "s-fork")

        vm.inputText = "/fork"
        await vm.send()

        XCTAssertTrue(messages(vm, containing: "Session forked."), "Expected /fork to report the fork")
        XCTAssertEqual(vm.inputText, "", "/fork should clear inputText")
    }

    private func compactionMarkers(_ vm: ChatViewModel) -> Int {
        vm.messages.filter {
            if case .systemEvent(let event) = $0.content { return event.kind == .compaction }
            return false
        }.count
    }

    func testSlashCompactSendsCompactToTheLiveSessionAndReportsTheCompaction() async throws {
        let (vm, mock) = try await vmAfterOneTurn(sessionID: "s-compact")
        mock.lastSessionOptions = nil
        mock.sendEventsQueue = [[.system(subtype: "compact_boundary", payload: [:])] + replyEvents(sessionID: "s-compact")]

        vm.inputText = "/compact"
        await vm.send()

        XCTAssertEqual(mock.lastSentMessage, "/compact", "/compact should go to the agent's session as a turn")
        XCTAssertNil(mock.lastSessionOptions, "/compact must not stop and restart the agent")
        XCTAssertEqual(compactionMarkers(vm), 1, "The session's compact_boundary should show as a marker")
        XCTAssertTrue(messages(vm, containing: "Context compacted."), "Expected /compact to report the compaction")
        XCTAssertFalse(vm.isStreaming)
        XCTAssertEqual(vm.inputText, "", "/compact should clear inputText")
    }

    func testSlashCompactWithoutACompactBoundarySaysNothingWasCompacted() async throws {
        let (vm, mock) = try await vmAfterOneTurn(sessionID: "s-compact")
        mock.sendEventsQueue = [replyEvents(sessionID: "s-compact")]

        vm.inputText = "/compact"
        await vm.send()

        XCTAssertEqual(mock.lastSentMessage, "/compact")
        XCTAssertEqual(compactionMarkers(vm), 0)
        XCTAssertFalse(messages(vm, containing: "Context compacted."), "A turn with no compact_boundary must not claim compaction")
        XCTAssertTrue(messages(vm, containing: "did not report a compaction"))
    }

    func testSlashCompactWithNoSessionYetSaysToSendAMessageFirst() async throws {
        let (vm, mock) = try await makeVM()

        vm.inputText = "/compact"
        await vm.send()

        XCTAssertTrue(messages(vm, containing: "No session to compact — send at least one message first."))
        XCTAssertNil(mock.lastSentMessage)
    }

    // MARK: - /history

    func testSlashHistoryAfterSlashModelNamesTheAgentsNewModel() async throws {
        let (vm, _) = try await makeVM()
        vm.inputText = "/model opus"
        await vm.send()

        vm.inputText = "/history"
        await vm.send()

        XCTAssertTrue(messages(vm, containing: "**Model:** \(ModelCatalog.displayName(for: "opus"))\n"),
                      "/history should name the model the agent now runs")
        XCTAssertFalse(messages(vm, containing: "**Model:** default"))
        XCTAssertFalse(messages(vm, containing: "**Model:** \(ModelCatalog.displayName(for: "sonnet"))\n"))
    }

    func testSlashHistoryNamesTheAgentsPermissionModeNotTheProjects() async throws {
        let (vm, _, orchestrator) = try await makeVMOverOrchestrator()
        let project = KiteloopProject(rootURL: tempDir)
        var config = project.loadConfig()
        config.permissionMode = "acceptEdits"
        try project.saveConfig(config)
        orchestrator.updateAgent(id: "test-agent") { $0.permissionMode = "plan" }

        vm.inputText = "/history"
        await vm.send()

        XCTAssertTrue(messages(vm, containing: "**Permission mode:** \(SettingNames.permissionMode("plan"))"))
        XCTAssertFalse(messages(vm, containing: "**Permission mode:** \(SettingNames.permissionMode("acceptEdits"))"))
    }

    func testSlashHistoryShowsNoSessionBeforeTheFirstTurn() async throws {
        let (vm, _) = try await makeVM()

        vm.inputText = "/history"
        await vm.send()

        XCTAssertTrue(messages(vm, containing: "**Session:** none\n"))
    }

    func testSlashHistoryShowsTheStoredSessionAfterATurn() async throws {
        let (vm, _) = try await vmAfterOneTurn(sessionID: "s-history")

        vm.inputText = "/history"
        await vm.send()

        XCTAssertTrue(messages(vm, containing: "**Session:** s-history\n"))
    }

    func testSlashHistoryForAnAgentNoLongerOnTheTeamSaysSo() async throws {
        let (vm, _, orchestrator) = try await makeVMOverOrchestrator()
        orchestrator.removeAgent("test-agent")

        vm.inputText = "/history"
        await vm.send()

        XCTAssertTrue(messages(vm, containing: "no longer on the team"))
        XCTAssertFalse(messages(vm, containing: "**Model:**"))
    }

    // MARK: - /fast

    func testSlashFastTogglesTheModelBothWays() async throws {
        let (vm, _) = try await makeVM()
        XCTAssertEqual(vm.agentModel, "sonnet", "Pre-condition: the agent starts on sonnet")

        vm.inputText = "/fast"
        await vm.send()

        XCTAssertEqual(vm.agentModel, "opus", "/fast off sonnet should switch to opus")
        XCTAssertTrue(messages(vm, containing: "Switched to **opus**."))

        vm.inputText = "/fast"
        await vm.send()

        XCTAssertEqual(vm.agentModel, "sonnet", "/fast again should switch back to sonnet")
        XCTAssertTrue(messages(vm, containing: "Switched to **sonnet**."))
    }

    func testSlashFastOnALocalAgentRefusesAndKeepsItsModel() async throws {
        let orchestrator = Orchestrator(runtime: MockAgentRuntime())
        orchestrator.addAgent(Agent(
            id: "local-agent", name: "LocalAgent", model: "llama3.1",
            systemPrompt: "", tools: [],
            denied: [], permissionMode: "default", state: .idle
        ))
        let vm = ChatViewModel(agentID: "local-agent", projectURL: tempDir, orchestrator: orchestrator)

        vm.inputText = "/fast"
        await vm.send()

        XCTAssertEqual(orchestrator.agents.first { $0.id == "local-agent" }?.model, "llama3.1")
        XCTAssertTrue(messages(vm, containing: "/fast switches between Claude models only"))
        XCTAssertTrue(messages(vm, containing: "/model <name>"))
        XCTAssertFalse(messages(vm, containing: "Switched to"))
        XCTAssertFalse(vm.messages.contains { if case .error = $0.content { return true }; return false })
        XCTAssertEqual(vm.inputText, "")
    }

    func testSlashEffortOnALocalAgentRefusesAndKeepsItsEffort() async throws {
        let (vm, orchestrator) = makeNonClaudeVM(model: "llama3.1")

        vm.inputText = "/effort high"
        await vm.send()

        XCTAssertNil(orchestrator.agents.first { $0.id == "other-agent" }?.effort)
        XCTAssertTrue(messages(vm, containing: "/effort applies to Claude agents only — this agent runs "
            + ModelCatalog.displayName(for: "llama3.1")))
        XCTAssertFalse(messages(vm, containing: "Effort set to"))
        XCTAssertFalse(messages(vm, containing: "Failed to restart"), "a refused /effort must not restart the agent")
        XCTAssertEqual(vm.inputText, "")
    }

    func testSlashThinkingOnALocalAgentRefusesAndKeepsItsThinking() async throws {
        let (vm, orchestrator) = makeNonClaudeVM(model: "llama3.1")

        for command in ["/thinking 8000", "/thinking on", "/thinking off"] {
            vm.inputText = command
            await vm.send()

            let agent = orchestrator.agents.first { $0.id == "other-agent" }
            XCTAssertEqual(agent?.thinkingEnabled, false, command)
            XCTAssertNil(agent?.thinkingBudget, command)
            XCTAssertEqual(vm.inputText, "", command)
        }
        XCTAssertTrue(messages(vm, containing: "/thinking applies to Claude agents only — this agent runs "
            + ModelCatalog.displayName(for: "llama3.1")))
        XCTAssertFalse(messages(vm, containing: "Extended thinking"))
        XCTAssertFalse(messages(vm, containing: "Failed to restart"), "a refused /thinking must not restart the agent")
    }

    func testSlashEffortAndThinkingOnACopilotAgentRefuse() async throws {
        let (vm, orchestrator) = makeNonClaudeVM(model: "copilot")

        vm.inputText = "/effort high"
        await vm.send()
        vm.inputText = "/thinking 8000"
        await vm.send()

        let agent = orchestrator.agents.first { $0.id == "other-agent" }
        XCTAssertNil(agent?.effort)
        XCTAssertEqual(agent?.thinkingEnabled, false)
        XCTAssertNil(agent?.thinkingBudget)
        XCTAssertTrue(messages(vm, containing: "/effort applies to Claude agents only"))
        XCTAssertTrue(messages(vm, containing: "/thinking applies to Claude agents only"))
        XCTAssertFalse(messages(vm, containing: "Effort set to"))
        XCTAssertFalse(messages(vm, containing: "Extended thinking"))
    }

    /// Gives the non-Claude agent a persisted session id, so a refusal cannot
    /// pass by hitting the "send at least one message first" branch instead.
    private func persistSessionIDForNonClaudeAgent() throws {
        let project = KiteloopProject(rootURL: tempDir)
        var config = project.loadConfig()
        config.agentSessionIDs = ["OtherAgent": "s-local"]
        try project.saveConfig(config)
    }

    private func agentMessages(_ vm: ChatViewModel) -> Int {
        vm.messages.filter { if case .agent = $0.sender { return true }; return false }.count
    }

    func testSlashForkOnALocalAgentRefusesAndLeavesTheSessionAlone() async throws {
        let (vm, _) = makeNonClaudeVM(model: "llama3.1")
        try persistSessionIDForNonClaudeAgent()

        vm.inputText = "/fork"
        await vm.send()

        XCTAssertTrue(messages(vm, containing: "/fork applies to Claude agents only — this agent runs "
            + ModelCatalog.displayName(for: "llama3.1")))
        XCTAssertFalse(messages(vm, containing: "Session forked"))
        XCTAssertFalse(messages(vm, containing: "Fork failed"))
        XCTAssertFalse(messages(vm, containing: "No session to fork"))
        XCTAssertEqual(vm.inputText, "")
    }

    func testSlashCompactOnALocalAgentRefusesAndSendsNothing() async throws {
        let (vm, _) = makeNonClaudeVM(model: "llama3.1")
        try persistSessionIDForNonClaudeAgent()

        vm.inputText = "/compact"
        await vm.send()

        XCTAssertTrue(messages(vm, containing: "/compact applies to Claude agents only — this agent runs "
            + ModelCatalog.displayName(for: "llama3.1")))
        XCTAssertEqual(agentMessages(vm), 0, "a refused /compact must send nothing to the agent")
        XCTAssertFalse(messages(vm, containing: "Context compacted"))
        XCTAssertFalse(messages(vm, containing: "did not report a compaction"))
        XCTAssertFalse(vm.isStreaming)
        XCTAssertEqual(vm.inputText, "")
    }

    func testSlashForkAsideOnALocalAgentRefusesAndOpensNoAside() async throws {
        let (vm, orchestrator) = makeNonClaudeVM(model: "llama3.1")
        try persistSessionIDForNonClaudeAgent()

        vm.inputText = "/fork aside"
        await vm.send()

        XCTAssertTrue(messages(vm, containing: "/fork aside applies to Claude agents only — this agent runs "
            + ModelCatalog.displayName(for: "llama3.1")))
        XCTAssertNil(orchestrator.aside(of: "other-agent"))
        XCTAssertFalse(messages(vm, containing: "Forked **"))
        XCTAssertEqual(vm.inputText, "")
    }

    func testSlashForkAndCompactOnACopilotAgentRefuse() async throws {
        let (vm, _) = makeNonClaudeVM(model: "copilot")
        try persistSessionIDForNonClaudeAgent()

        vm.inputText = "/fork"
        await vm.send()
        vm.inputText = "/compact"
        await vm.send()

        XCTAssertTrue(messages(vm, containing: "/fork applies to Claude agents only"))
        XCTAssertTrue(messages(vm, containing: "/compact applies to Claude agents only"))
        XCTAssertFalse(messages(vm, containing: "Session forked"))
        XCTAssertFalse(messages(vm, containing: "Context compacted"))
        XCTAssertFalse(messages(vm, containing: "did not report a compaction"))
        XCTAssertEqual(agentMessages(vm), 0)
    }

    private func makeNonClaudeVM(model: String) -> (ChatViewModel, Orchestrator) {
        let orchestrator = Orchestrator(runtime: MockAgentRuntime())
        orchestrator.addAgent(Agent(
            id: "other-agent", name: "OtherAgent", model: model,
            systemPrompt: "", tools: [],
            denied: [], permissionMode: "default", state: .idle
        ))
        let vm = ChatViewModel(agentID: "other-agent", projectURL: tempDir, orchestrator: orchestrator)
        return (vm, orchestrator)
    }

    // MARK: - /thinking

    func testSlashThinkingWithABudgetEnablesItAndOffClearsIt() async throws {
        let (vm, _, orchestrator) = try await makeVMOverOrchestrator()

        vm.inputText = "/thinking 8000"
        await vm.send()

        XCTAssertEqual(testAgent(in: orchestrator)?.thinkingEnabled, true)
        XCTAssertEqual(testAgent(in: orchestrator)?.thinkingBudget, 8000)
        XCTAssertTrue(messages(vm, containing: "budget: 8000 tokens"))

        vm.inputText = "/thinking off"
        await vm.send()

        XCTAssertEqual(testAgent(in: orchestrator)?.thinkingEnabled, false)
        XCTAssertNil(testAgent(in: orchestrator)?.thinkingBudget, "off should clear the budget, not keep it")
        XCTAssertTrue(messages(vm, containing: "Extended thinking disabled."))
    }

    func testSlashThinkingWithAnArgumentThatIsNoBudgetChangesNothing() async throws {
        let (vm, _, orchestrator) = try await makeVMOverOrchestrator()

        vm.inputText = "/thinking sometimes"
        await vm.send()

        XCTAssertTrue(messages(vm, containing: "Usage: /thinking [on|off|<budget_tokens>]"))
        XCTAssertEqual(testAgent(in: orchestrator)?.thinkingEnabled, false, "A bad argument must not enable thinking")
        XCTAssertNil(testAgent(in: orchestrator)?.thinkingBudget)
    }

    func testSlashThinkingWithAZeroBudgetIsRefusedAndChangesNothing() async throws {
        let (vm, _, orchestrator) = try await makeVMOverOrchestrator()

        vm.inputText = "/thinking 0"
        await vm.send()

        XCTAssertTrue(messages(vm, containing: "Usage: /thinking [on|off|<budget_tokens>]"))
        XCTAssertEqual(testAgent(in: orchestrator)?.thinkingEnabled, false, "A zero budget must not enable thinking")
        XCTAssertNil(testAgent(in: orchestrator)?.thinkingBudget)
    }

    func testSlashThinkingWithANegativeBudgetIsRefusedAndChangesNothing() async throws {
        let (vm, _, orchestrator) = try await makeVMOverOrchestrator()

        vm.inputText = "/thinking -500"
        await vm.send()

        XCTAssertTrue(messages(vm, containing: "Usage: /thinking [on|off|<budget_tokens>]"))
        XCTAssertFalse(messages(vm, containing: "budget: -500 tokens"), "A budget nothing reads must not be reported")
        XCTAssertEqual(testAgent(in: orchestrator)?.thinkingEnabled, false, "A negative budget must not enable thinking")
        XCTAssertNil(testAgent(in: orchestrator)?.thinkingBudget)
    }

    // MARK: - /undo

    func testSlashUndoRemovesTheLastTurnAndLeavesTheOneBefore() async throws {
        let (vm, mock) = try await makeVM(events: replyEvents(sessionID: "s-undo"))

        vm.inputText = "first question"
        await vm.send()
        vm.inputText = "second question"
        await vm.send()
        XCTAssertTrue(messages(vm, containing: "second question"), "Pre-condition: both turns are on the transcript")
        mock.lastSessionOptions = nil

        vm.inputText = "/undo"
        await vm.send()

        XCTAssertFalse(messages(vm, containing: "second question"), "/undo should drop the last human turn")
        XCTAssertTrue(messages(vm, containing: "first question"), "/undo should leave the turn before it alone")
        XCTAssertTrue(messages(vm, containing: "Undid last turn"))
        XCTAssertTrue(messages(vm, containing: "the agent still remembers the earlier conversation"),
                      "/undo should say the agent's session still holds the undone turn")
        XCTAssertTrue(messages(vm, containing: "`/clear`"), "/undo should name /clear as the way to start fresh")
        XCTAssertNil(mock.lastSessionOptions, "/undo must not stop and restart the agent")
    }

    func testSlashUndoPutsTheMessageItTookBackInTheInput() async throws {
        let (vm, _) = try await makeVM(events: replyEvents(sessionID: "s-undo-input"))
        vm.inputText = "first question"
        await vm.send()
        vm.inputText = "second question"
        await vm.send()

        vm.inputText = "/undo"
        await vm.send()

        XCTAssertEqual(vm.inputText, "second question", "/undo should hand the undone message back to edit and resend")
        XCTAssertFalse(messages(vm, containing: "second question"), "The message goes back to the input, not the transcript")
        XCTAssertTrue(messages(vm, containing: "back in the input"), "/undo should say where the message went")
    }

    func testSlashUndoWithNothingSaidYetSaysSo() async throws {
        let (vm, _) = try await makeVM()

        vm.inputText = "/undo"
        await vm.send()

        XCTAssertTrue(messages(vm, containing: "Nothing to undo."))
        XCTAssertEqual(vm.inputText, "", "Nothing undone, nothing to put back in the input")
    }

    func testSlashUndoWhileTheAgentStreamsLeavesTheMessageAndTheInputAlone() async throws {
        let (vm, mock) = try await makeVM(events: replyEvents(sessionID: "s-undo-streaming"))
        mock.startDelay = 300_000_000
        vm.inputText = "second question"
        let turn = Task { await vm.send() }
        try await eventually("the turn is streaming") { vm.isStreaming }

        vm.inputText = "/undo"
        await vm.send()

        XCTAssertTrue(vm.isStreaming)
        XCTAssertTrue(messages(vm, containing: "second question"), "/undo mid-turn must not take the message off the transcript")
        XCTAssertEqual(vm.inputText, "", "/undo mid-turn must not put the message back in the input")
        await turn.value
    }

    // MARK: - A rewritten transcript is on disk

    /// A store to save into, on a session that already carries a title: an
    /// untitled one would send `saveMessages` off to generate one.
    private func attachTitledSessionStore(to vm: ChatViewModel) throws -> (store: SessionStore, session: ChatSession) {
        let store = SessionStore(projectDir: try makeTemporaryDirectory(prefix: "kiteloop-slash-sessions"))
        var session = store.createSession(agentID: "test-agent")
        session.title = "Named"
        store.updateSession(session)
        vm.setupSessionStore(store)
        return (store, session)
    }

    /// What a relaunch would load: the session's history as it is on disk.
    private func onDisk(_ store: SessionStore, _ session: ChatSession) -> [Message] {
        store.loadMessageTail(for: session, limit: 500).messages
    }

    private func onDisk(_ store: SessionStore, _ session: ChatSession, containing substring: String) -> Bool {
        onDisk(store, session).contains { msg in
            if case .text(let t) = msg.content { return t.contains(substring) }
            return false
        }
    }

    /// Sends `text` and waits until the turn's own save has reached disk, so
    /// the write a test then checks for is the only one still in flight.
    private func sendAndWaitForDisk(_ text: String, _ vm: ChatViewModel, _ store: SessionStore, _ session: ChatSession) async throws {
        vm.inputText = text
        await vm.send()
        try await eventually("'\(text)' on disk") { self.onDisk(store, session, containing: text) }
    }

    func testSlashUndoIsOnDiskWithoutAnotherMessage() async throws {
        let (vm, _) = try await makeVM(events: replyEvents(sessionID: "s-undo-disk"))
        let (store, session) = try attachTitledSessionStore(to: vm)
        try await sendAndWaitForDisk("first question", vm, store, session)
        try await sendAndWaitForDisk("second question", vm, store, session)

        vm.inputText = "/undo"
        await vm.send()

        try await eventually("the undone turn gone from disk, the one before kept") {
            !self.onDisk(store, session, containing: "second question")
                && self.onDisk(store, session, containing: "first question")
        }
    }

    func testSlashClearIsOnDisk() async throws {
        let (vm, _) = try await makeVM(events: replyEvents(sessionID: "s-clear-disk"))
        let (store, session) = try attachTitledSessionStore(to: vm)
        try await sendAndWaitForDisk("before the clear", vm, store, session)
        let before = Set(vm.messages.map(\.id))

        vm.inputText = "/clear"
        await vm.send()

        try await eventually("no message from before the clear on disk") {
            self.onDisk(store, session).allSatisfy { !before.contains($0.id) }
        }
    }

    func testSlashBranchSwitchAndMainAreOnDisk() async throws {
        let (vm, _) = try await makeVM(events: replyEvents(sessionID: "s-branch-disk"))
        let (store, session) = try attachTitledSessionStore(to: vm)
        try await sendAndWaitForDisk("main message 1", vm, store, session)
        vm.inputText = "/branch mybranch"
        await vm.send()

        vm.inputText = "/branch switch mybranch"
        await vm.send()
        try await eventually("the branch's transcript on disk") {
            self.onDisk(store, session).map(\.id) == vm.messages.map(\.id)
        }

        try await sendAndWaitForDisk("branch message", vm, store, session)
        vm.inputText = "/branch main"
        await vm.send()
        XCTAssertFalse(messages(vm, containing: "branch message"), "Pre-condition: main is on screen")
        try await eventually("main's transcript on disk") {
            self.onDisk(store, session).map(\.id) == vm.messages.map(\.id)
        }
    }

    func testSidebarBranchSwitchesAreOnDisk() async throws {
        let (vm, _) = try await makeVM(events: replyEvents(sessionID: "s-sidebar-disk"))
        let (store, session) = try attachTitledSessionStore(to: vm)
        try await sendAndWaitForDisk("main message 1", vm, store, session)
        vm.inputText = "/branch mybranch"
        await vm.send()
        let branchID = try XCTUnwrap(vm.conversationTree.branches.first { $0.name == "mybranch" }?.id)

        vm.switchToBranch(id: branchID)
        try await eventually("the branch's transcript on disk") {
            self.onDisk(store, session).map(\.id) == vm.messages.map(\.id)
        }

        try await sendAndWaitForDisk("branch message", vm, store, session)
        vm.switchToMainBranch()
        XCTAssertFalse(messages(vm, containing: "branch message"), "Pre-condition: main is on screen")
        try await eventually("main's transcript on disk") {
            self.onDisk(store, session).map(\.id) == vm.messages.map(\.id)
        }
    }

    // MARK: - /loop

    /// `/loop` runs until it is stopped, so the command goes on a task of its
    /// own. The runtime is held inside the first turn by `startDelay`, which is
    /// what makes `lastSentMessage` the *first* prompt and not a later
    /// "Continue." one; the loop is then cancelled and awaited to a stop.
    private func firstLoopPrompt(
        _ command: String
    ) async throws -> (prompt: String, vm: ChatViewModel) {
        let (vm, mock) = try await makeVM(events: replyEvents(sessionID: "s-loop"))
        mock.startDelay = 500_000_000
        vm.inputText = command

        let running = Task { await vm.send() }
        try await eventually("the loop's first prompt to reach the runtime") {
            vm.activeGoal != nil && mock.lastSentMessage != nil
        }
        let prompt = mock.lastSentMessage ?? ""

        vm.cancelGoal()
        await running.value
        return (prompt, vm)
    }

    func testSlashLoopWithAnInstructionStartsALoopOnThatInstruction() async throws {
        let (prompt, vm) = try await firstLoopPrompt("/loop keep the tests green")

        XCTAssertEqual(prompt, "keep the tests green", "The instruction is the loop's first prompt")
        XCTAssertTrue(messages(vm, containing: "Loop started."))
        XCTAssertNil(vm.activeGoal, "Cancelling should end the loop")
    }

    func testSlashLoopWithNoInstructionStartsALoopOnTheDefaultNextStep() async throws {
        let (prompt, vm) = try await firstLoopPrompt("/loop")

        XCTAssertEqual(prompt, "Continue working on the current task. Take the next logical step.",
                       "A bare /loop falls back to the next-step prompt")
        XCTAssertTrue(messages(vm, containing: "Loop started."))
    }

    func testSlashLoopStatusWithNoLoopRunningExplainsTheUsage() async throws {
        let (vm, mock) = try await makeVM()

        vm.inputText = "/loop status"
        await vm.send()

        XCTAssertTrue(messages(vm, containing: "No loop is running. Usage: `/loop [instruction]`"))
        XCTAssertNil(mock.lastSentMessage, "A status report must not send a prompt")
    }

    func testSlashLoopStopWithNoLoopRunningSaysSo() async throws {
        let (vm, _) = try await makeVM()

        vm.inputText = "/loop stop"
        await vm.send()

        XCTAssertTrue(messages(vm, containing: "No loop is running."))
        XCTAssertFalse(messages(vm, containing: "Goal cancelled."), "There was nothing to cancel")
    }

    // MARK: - /goal

    func testSlashGoalSetsTheConditionAndClearsItOnGoalComplete() async throws {
        let (vm, mock) = try await makeVM(events: [
            .assistantText("Shipped it.\nGOAL_COMPLETE"),
            .result(.init(
                text: "Shipped it.\nGOAL_COMPLETE", costUSD: 0.002, durationMs: 10,
                inputTokens: 2, outputTokens: 2,
                cacheCreationInputTokens: 0, cacheReadInputTokens: 0,
                sessionID: "s-goal", permissionDenials: []
            ))
        ])

        vm.inputText = "/goal the tests are green"
        await vm.send()

        XCTAssertTrue(messages(vm, containing: "Goal set: **the tests are green**"))
        XCTAssertTrue(mock.lastSentMessage?.contains("**Goal:** the tests are green") == true,
                      "The condition should reach the agent in the goal prompt")
        XCTAssertTrue(messages(vm, containing: "Goal achieved in 1 turns"))
        XCTAssertNil(vm.activeGoal, "GOAL_COMPLETE should clear the goal")
    }

    func testSlashGoalWithNoArgumentAndNoActiveGoalExplainsTheUsage() async throws {
        let (vm, mock) = try await makeVM()

        vm.inputText = "/goal"
        await vm.send()

        XCTAssertTrue(messages(vm, containing: "No active goal."))
        XCTAssertNil(mock.lastSentMessage, "Asking after a goal must not send a prompt")
    }

    /// The cancel arm, reached with nothing running: there is nothing to
    /// cancel, so it says so rather than claiming a cancel.
    func testSlashGoalCancelClearsTheGoalAndSaysSo() async throws {
        let (vm, _) = try await makeVM()

        vm.inputText = "/goal cancel"
        await vm.send()

        XCTAssertTrue(messages(vm, containing: "No goal is running."))
        XCTAssertFalse(messages(vm, containing: "Goal cancelled."), "There was nothing to cancel")
        XCTAssertNil(vm.activeGoal)
        XCTAssertEqual(vm.inputText, "", "/goal cancel should clear inputText")
    }

    // MARK: - Stopping a running loop or goal

    /// Starts `command` and waits until its first turn is held open by the
    /// runtime's `startDelay`, so the turn is streaming when the test types.
    private func runningLoop(
        _ command: String
    ) async throws -> (vm: ChatViewModel, mock: MockAgentRuntime, running: Task<Void, Never>) {
        let (vm, mock) = try await makeVM(events: replyEvents(sessionID: "s-stop"))
        mock.startDelay = 500_000_000
        vm.inputText = command
        let running = Task { await vm.send() }
        try await eventually("the first turn to be streaming") {
            vm.activeGoal != nil && vm.isStreaming && mock.lastSentMessage != nil
        }
        return (vm, mock, running)
    }

    private func count(_ vm: ChatViewModel, containing substring: String) -> Int {
        vm.messages.filter {
            if case .text(let text) = $0.content { return text.contains(substring) }
            return false
        }.count
    }

    func testSlashLoopStopTypedDuringALoopStopsItWithoutRunningTheRemainingTurns() async throws {
        let (vm, mock, running) = try await runningLoop("/loop keep the tests green")

        vm.inputText = "a note for later"
        await vm.send()
        XCTAssertEqual(vm.queuedMessageCount, 1, "Any other message typed during a loop is still queued")

        vm.inputText = "/loop stop"
        await vm.send()

        XCTAssertNil(vm.activeGoal, "/loop stop should end the loop straight away")
        XCTAssertEqual(vm.inputText, "")
        XCTAssertEqual(vm.queuedMessageCount, 1, "The stop must not wait in the queue to run again")
        await running.value
        XCTAssertFalse(mock.sentMessages.contains { $0.message == "Continue. Take the next step." },
                       "A stopped loop must send no further turns")
        XCTAssertEqual(count(vm, containing: "Goal cancelled."), 1)
    }

    func testSlashGoalCancelTypedDuringAGoalStopsItAndSaysSoOnce() async throws {
        let (vm, mock, running) = try await runningLoop("/goal the tests are green")

        vm.inputText = "/goal cancel"
        await vm.send()

        XCTAssertNil(vm.activeGoal, "/goal cancel should end the goal straight away")
        XCTAssertEqual(vm.queuedMessageCount, 0, "The cancel must not wait in the queue")
        await running.value
        XCTAssertEqual(mock.sentMessages.count, 1, "A cancelled goal must send no further turns")
        XCTAssertEqual(count(vm, containing: "Goal cancelled."), 1)
    }

    // MARK: - Read-only commands typed during a turn

    /// Sends a plain message and waits until its turn is held open by the
    /// runtime's `startDelay`, so the turn is streaming when the test types.
    private func streamingTurn() async throws -> (vm: ChatViewModel, mock: MockAgentRuntime, running: Task<Void, Never>) {
        let (vm, mock) = try await makeVM(events: replyEvents(sessionID: "s-turn"))
        mock.startDelay = 500_000_000
        vm.inputText = "Hello"
        let running = Task { await vm.send() }
        try await eventually("the turn to be streaming") { vm.isStreaming && mock.lastSentMessage != nil }
        return (vm, mock, running)
    }

    func testSlashLoopStatusTypedDuringALoopReportsTheRunningLoop() async throws {
        let (vm, mock, running) = try await runningLoop("/loop keep the tests green")

        vm.inputText = "/loop status"
        await vm.send()

        XCTAssertEqual(count(vm, containing: "Loop running:"), 1, "/loop status should report the loop it was asked about")
        XCTAssertNotNil(vm.activeGoal, "Asking after the loop must not stop it")
        XCTAssertEqual(vm.queuedMessageCount, 0, "/loop status must not wait in the queue")
        XCTAssertEqual(vm.inputText, "")
        XCTAssertEqual(mock.sentMessages.count, 1, "/loop status must send nothing to the agent")

        vm.inputText = "/loop stop"
        await vm.send()
        await running.value
    }

    func testSlashGoalStatusAndBareGoalTypedDuringAGoalReportItAtOnce() async throws {
        let (vm, mock, running) = try await runningLoop("/goal the tests are green")

        vm.inputText = "/goal status"
        await vm.send()
        vm.inputText = "/Goal"
        await vm.send()

        XCTAssertEqual(count(vm, containing: "Active goal:"), 2, "/goal status and bare /goal should each report the goal")
        XCTAssertNotNil(vm.activeGoal)
        XCTAssertEqual(vm.queuedMessageCount, 0, "Neither report may wait in the queue")
        XCTAssertEqual(mock.sentMessages.count, 1, "Asking after the goal must send nothing to the agent")

        vm.inputText = "/goal cancel"
        await vm.send()
        await running.value
    }

    func testSlashCostAndContextTypedDuringATurnAnswerAtOnce() async throws {
        let (vm, mock, running) = try await streamingTurn()

        vm.inputText = "/cost"
        await vm.send()
        vm.inputText = "/context"
        await vm.send()

        XCTAssertEqual(count(vm, containing: "Session Cost:"), 1, "/cost should answer during the turn")
        XCTAssertEqual(count(vm, containing: "Context window:"), 1, "/context should answer during the turn")
        XCTAssertTrue(vm.isStreaming, "The turn must carry on untouched")
        XCTAssertEqual(vm.queuedMessageCount, 0)
        await running.value
        XCTAssertEqual(mock.sentMessages.map(\.message), ["Hello"], "The reports must send nothing to the agent")
    }

    func testSlashDoctorTypedDuringATurnAnswersAtOnce() async throws {
        let (vm, mock, running) = try await streamingTurn()

        vm.inputText = "/doctor"
        await vm.send()

        XCTAssertEqual(count(vm, containing: "Kiteloop Diagnostics"), 1, "/doctor should answer during the turn")
        XCTAssertTrue(vm.isStreaming, "The turn must carry on untouched")
        XCTAssertEqual(vm.queuedMessageCount, 0, "/doctor must not wait in the queue")
        await running.value
        XCTAssertEqual(mock.sentMessages.map(\.message), ["Hello"], "/doctor must send nothing to the agent")
    }

    func testMessagesAndStateChangingCommandsTypedDuringATurnAreStillQueued() async throws {
        let (vm, _, running) = try await streamingTurn()

        for typed in ["a note for later", "/model sonnet", "/clear"] {
            vm.inputText = typed
            await vm.send()
        }

        XCTAssertEqual(vm.queuedMessageCount, 3, "Only read-only reports skip the queue")
        XCTAssertFalse(messages(vm, containing: "Switched to model"), "/model <name> must wait for the turn to end")
        await running.value
    }
}
