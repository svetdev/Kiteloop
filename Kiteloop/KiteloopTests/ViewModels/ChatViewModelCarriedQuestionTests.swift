import XCTest
import KiteloopCore
@testable import Kiteloop

/// A chat reopened on a question nobody answered — asked by a session that
/// ended with the app — still holds the question, and answering it says the
/// answer to the agent rather than returning a call nothing waits on.
@MainActor
final class ChatViewModelCarriedQuestionTests: XCTestCase {

    private var mock: MockAgentRuntime!
    private var orchestrator: Orchestrator!

    private static func done() -> StreamEvent {
        .result(.init(text: "done", costUSD: 0.001, durationMs: 100, inputTokens: 10, outputTokens: 5,
                      cacheCreationInputTokens: 0, cacheReadInputTokens: 0, sessionID: "s1", permissionDenials: []))
    }

    private var asked: Message {
        Message(id: UUID(), timestamp: .now, sender: .agent("chief"),
                content: .approval(.init(id: "ask-1", action: "Ship on Friday?", tool: "ask_human")))
    }

    private var choices: Message {
        let input = #"{"questions":[{"question":"Who reviews?","header":"Reviewer","multiSelect":false,"options":[{"label":"A","description":""},{"label":"B","description":""}]}]}"#
        return PermissionCards.card(for: PermissionPrompt.Request(id: "req-2", toolName: "AskUserQuestion", input: input),
                                    subagent: nil, agentID: "chief")
    }

    /// A chat view model opened on `saved`, as a relaunch opens one.
    private func reopened(on saved: [Message]) async throws -> ChatViewModel {
        let directory = try makeTemporaryDirectory(prefix: "carried-question")
        let store = SessionStore(projectDir: directory)
        let session = store.createSession(agentID: "chief")
        try SessionStore.writeMessages(saved, to: store.messagesURL(for: session), keepingLeading: 0)

        mock = MockAgentRuntime()
        mock.events = [Self.done()]
        orchestrator = Orchestrator(runtime: mock)
        orchestrator.addAgent(Agent(id: "chief", name: "Chief", model: "sonnet", systemPrompt: "", tools: [],
                                    denied: [], permissionMode: "auto", state: .idle))
        try await orchestrator.startAgent("chief", cwd: directory)
        let vm = ChatViewModel(agentID: "chief", projectURL: directory, orchestrator: orchestrator)
        vm.setupSessionStore(store)
        return vm
    }

    private var state: Agent.AgentState? { orchestrator.agents.first?.state }

    func testAChatLeftOnAQuestionStillWaitsOnItAfterARelaunch() async throws {
        let vm = try await reopened(on: [.human("plan the week"), asked])

        XCTAssertEqual(vm.pendingHumanToolCallID, "ask-1")
        XCTAssertEqual(state, .waitingForHuman)
    }

    func testAnsweringACarriedQuestionSaysTheAnswerToTheAgent() async throws {
        let vm = try await reopened(on: [asked])
        vm.inputText = "a draft in progress"

        await vm.respondToHuman(requestID: "ask-1", answer: "Yes, after the demo.")

        XCTAssertEqual(mock.sentMessages.map(\.message),
                       ["Answering your earlier question — “Ship on Friday?”:\n\nYes, after the demo."])
        XCTAssertTrue(mock.toolResultsSent.isEmpty, "there is no call left to return the answer to")
        XCTAssertNil(vm.pendingHumanToolCallID)
        XCTAssertEqual(vm.inputText, "a draft in progress", "what was being typed is left alone")
        let request = vm.messages.compactMap { message -> Message.ApprovalRequest? in
            if case .approval(let request) = message.content { return request }
            return nil
        }.first
        XCTAssertEqual(request?.status, .approved)
    }

    func testAQuestionWithSomethingAfterItIsNotCarried() async throws {
        let vm = try await reopened(on: [asked, .human("never mind")])

        XCTAssertNil(vm.pendingHumanToolCallID)
        XCTAssertNotEqual(state, .waitingForHuman)
    }

    func testAChatLeftOnTheModelsQuestionsKeepsTheCardOpenAndSaysTheAnswers() async throws {
        let vm = try await reopened(on: [choices])
        XCTAssertEqual(vm.openPromptCount, 1)
        XCTAssertEqual(state, .waitingForHuman)

        XCTAssertTrue(vm.answerChoices(requestID: "req-2", answers: ["A"]))

        try await eventually("the answer reached the agent") {
            self.mock.sentMessages.map(\.message) == ["Answering your earlier question — “Who reviews?”:\n\nA"]
        }
        XCTAssertTrue(mock.controlLines.isEmpty, "the session that asked is gone: nothing is answered over its channel")
        XCTAssertEqual(vm.openPromptCount, 0)
        XCTAssertFalse(vm.answerChoices(requestID: "req-2", answers: ["B"]), "a card is answered once")
    }

    func testAnOpenCardThatIsNotTheLastThingSaidLapsesAsBefore() async throws {
        let vm = try await reopened(on: [choices, .human("moving on")])

        XCTAssertEqual(vm.openPromptCount, 0)
        XCTAssertFalse(vm.answerChoices(requestID: "req-2", answers: ["A"]))
    }

    // MARK: - Asked over the tool bridge

    /// `ask_human` reaches Kiteloop as a call on its tool bridge, which holds
    /// the call open: the question is put to the person and the answer goes
    /// back as that call's reply, inside the turn that asked.
    func testAQuestionAskedOverTheToolBridgeWaitsOnThePersonAndTheirAnswerIsItsReply() async throws {
        let directory = try makeTemporaryDirectory(prefix: "bridge-question")
        mock = MockAgentRuntime()
        mock.events = [
            .mcpToolCall(.init(requestID: "bridge-1", toolName: "ask_human", input: #"{"question":"Red or blue?"}"#)),
            Self.done()
        ]
        orchestrator = Orchestrator(runtime: mock)
        orchestrator.addAgent(Agent(id: "chief", name: "Chief", model: "sonnet", systemPrompt: "", tools: [],
                                    denied: [], permissionMode: "auto", state: .idle))
        orchestrator.configureNotifications(notificationsURL: directory.appending(path: "notifications.log"))
        try await orchestrator.startAgent("chief", cwd: directory)
        let vm = ChatViewModel(agentID: "chief", projectURL: directory, orchestrator: orchestrator)

        vm.inputText = "ask me"
        await vm.send()

        XCTAssertEqual(vm.pendingHumanToolCallID, "bridge-1")
        XCTAssertTrue(mock.mcpToolResults.isEmpty, "nothing is answered for the person")

        await vm.respondToHuman(requestID: "bridge-1", answer: "blue")

        XCTAssertEqual(mock.mcpToolResults, ["blue"])
        XCTAssertTrue(mock.toolResultsSent.isEmpty)
        XCTAssertNil(vm.pendingHumanToolCallID)
    }
}
