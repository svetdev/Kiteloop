import XCTest
import KiteloopCore
@testable import Kiteloop

/// Answering an `ask_human` question leaves the question where the agent asked
/// it — the bubble is marked answered, and the answer goes below it as the
/// human message.
@MainActor
final class ChatViewModelAskHumanTests: XCTestCase {
    private let question = "Which port should the server bind to?"
    private let answer = "8080"
    private let toolCallID = "ask-1"

    private var vm: ChatViewModel!
    private var mock: MockAgentRuntime!
    private var orchestrator: Orchestrator!

    private static func doneResult() -> StreamEvent {
        .result(.init(
            text: "done",
            costUSD: 0.001, durationMs: 100,
            inputTokens: 10, outputTokens: 5,
            cacheCreationInputTokens: 0, cacheReadInputTokens: 0,
            sessionID: "s1", permissionDenials: []
        ))
    }

    override func setUp() async throws {
        let mock = MockAgentRuntime()
        self.mock = mock
        // The turn reaches `ask_human`, which is what sets
        // `pendingHumanToolCallID` — the property is `private(set)`, so the
        // stream is the only way to arrive at the paused state.
        mock.events = [
            .toolUse(id: toolCallID, name: "ask_human", input: "{\"question\": \"\(question)\"}"),
            Self.doneResult(),
        ]
        mock.toolResultEvents = [Self.doneResult()]

        let orchestrator = Orchestrator(runtime: mock)
        self.orchestrator = orchestrator
        let agent = Agent(
            id: "test", name: "Test", model: "sonnet",
            systemPrompt: "", tools: [],
            denied: [], permissionMode: "default", state: .idle
        )
        orchestrator.addAgent(agent)

        let tmpDir = try makeTemporaryDirectory(prefix: "kiteloop-test")
        // The inbox the question's notice is filed in, so a test can watch it
        // close when the question is answered.
        orchestrator.configureNotifications(notificationsURL: tmpDir.appending(path: "notifications.log"))
        vm = ChatViewModel(agentID: "test", projectURL: tmpDir, orchestrator: orchestrator)
        try await orchestrator.startAgent("test", cwd: tmpDir)

        vm.inputText = "start it"
        await vm.send()

        XCTAssertEqual(vm.pendingHumanToolCallID, toolCallID)
    }

    /// The ask_human bubble as it stands now, found by the tool call's id.
    private var askHumanRequest: Message.ApprovalRequest? {
        for message in vm.messages.reversed() {
            if case .approval(let req) = message.content, req.id == toolCallID { return req }
        }
        return nil
    }

    func testTheQuestionSurvivesTheAnswer() async throws {
        await vm.respondToHuman(requestID: toolCallID, answer: answer)

        XCTAssertEqual(try XCTUnwrap(askHumanRequest).action, question)
    }

    func testTheAnsweredRequestKeepsItsIdentityAndIsApproved() async throws {
        await vm.respondToHuman(requestID: toolCallID, answer: answer)

        let req = try XCTUnwrap(askHumanRequest)
        XCTAssertEqual(req.status, .approved)
        XCTAssertEqual(req.id, toolCallID)
        XCTAssertEqual(req.tool, "ask_human")
    }

    func testTheAnswerIsOnTheTranscriptExactlyOnce() async throws {
        await vm.respondToHuman(requestID: toolCallID, answer: answer)

        let occurrences = vm.messages.filter { message in
            switch message.content {
            case .text(let text): return text == answer
            case .approval(let req): return req.action == answer
            default: return false
            }
        }
        XCTAssertEqual(occurrences.count, 1)
        XCTAssertEqual(occurrences.first?.sender, .human)
    }

    // MARK: - Answering the call the session is actually waiting on

    func testTheAnswerGoesToTheCallTheSessionIsWaitingOn() async throws {
        await vm.respondToHuman(requestID: toolCallID, answer: answer)

        XCTAssertEqual(mock.toolResultsSent.map(\.toolCallID), [toolCallID])
        XCTAssertEqual(mock.toolResultsSent.first?.content, answer)
    }

    func testAnsweringAnotherRequestSendsNothingAndSaysNothing() async throws {
        await vm.respondToHuman(requestID: "ask-from-another-turn", answer: answer)

        XCTAssertTrue(mock.toolResultsSent.isEmpty)
        XCTAssertFalse(vm.messages.contains { message in
            guard case .text(let text) = message.content else { return false }
            return message.sender == .human && text == answer
        })
        // Still waiting: the pending call is untouched by the stray answer.
        XCTAssertEqual(vm.pendingHumanToolCallID, toolCallID)
    }

    // MARK: - A blank answer

    func testAnAnswerOfOnlyLineBreaksLeavesTheQuestionOpen() async throws {
        for blank in ["\n\n", " \n "] {
            let messageCount = vm.messages.count

            await vm.respondToHuman(requestID: toolCallID, answer: blank)

            XCTAssertEqual(vm.pendingHumanToolCallID, toolCallID)
            XCTAssertEqual(try XCTUnwrap(askHumanRequest).status, .pending)
            XCTAssertEqual(vm.messages.count, messageCount)
            XCTAssertTrue(mock.toolResultsSent.isEmpty)
        }
    }

    // MARK: - The notice the question filed

    /// The inbox the question's notice landed in, once it has landed: the file
    /// happens on a `Task`, so a test that resolved before it landed would be
    /// resolving nothing.
    private func inboxHoldingTheQuestion() async throws -> NotificationStore {
        let store = try XCTUnwrap(orchestrator.notificationStore)
        try await eventually("the question notice filed") {
            await store.pending().contains { $0.type == .question && $0.agentID == "test" }
        }
        return store
    }

    /// The notice says where the asking agent lives, which is what lets its
    /// row in the popover open the agent's chat.
    func testTheNoticeCarriesTheAskingAgentsProjectRoot() async throws {
        let store = try await inboxHoldingTheQuestion()

        let pending = await store.pending()
        let notice = try XCTUnwrap(pending.first { $0.type == .question })
        XCTAssertEqual(notice.projectPath, vm.projectURL.path(percentEncoded: false))
        XCTAssertNil(notice.itemID)
    }

    func testAnsweringTheQuestionResolvesTheNoticeItFiled() async throws {
        let store = try await inboxHoldingTheQuestion()
        let before = await store.actionablePendingCount()

        await vm.respondToHuman(requestID: toolCallID, answer: answer)

        try await eventually("the notice resolved as answered") {
            await store.pending().isEmpty
        }
        let resolved = await store.resolved()
        XCTAssertEqual(resolved.first?.type, .question)
        XCTAssertEqual(resolved.first?.resolution, "answered")
        // The badge counts actionable pending rows, so this is the badge
        // dropping by one with nobody clicking ✓ in the inbox.
        let after = await store.actionablePendingCount()
        XCTAssertEqual(after, before - 1)
    }

    func testAnsweringLeavesAnotherAgentsQuestionPending() async throws {
        let store = try await inboxHoldingTheQuestion()
        await store.add(NotificationItem(agentID: "other", type: .question,
                                         title: "Other needs input", body: "Which branch?"))

        await vm.respondToHuman(requestID: toolCallID, answer: answer)

        try await eventually("only this agent's question resolved") {
            await store.pending().map(\.agentID) == ["other"]
        }
    }

    func testAnsweringARequestTheSessionHasMovedPastResolvesNoNotice() async throws {
        let store = try await inboxHoldingTheQuestion()

        await vm.respondToHuman(requestID: "ask-from-another-turn", answer: answer)

        let pending = await store.pending()
        let resolved = await store.resolved()
        XCTAssertEqual(pending.count, 1)
        XCTAssertTrue(resolved.isEmpty)
    }

    // MARK: - The question dies with the session behind it

    /// Puts the view model on a store with a second session to switch to.
    private func attachSessionStore() throws -> SessionStore {
        let dir = try makeTemporaryDirectory(prefix: "kiteloop-ask-human-sessions")
        let store = SessionStore(projectDir: dir)
        vm.setupSessionStore(store)
        return store
    }

    func testRestartingDropsThePendingQuestion() async throws {
        await vm.restart()

        XCTAssertNil(vm.pendingHumanToolCallID)
    }

    func testClearingDropsThePendingQuestion() async throws {
        await vm.clear()

        XCTAssertNil(vm.pendingHumanToolCallID)
    }

    func testStartingANewChatDropsThePendingQuestion() async throws {
        _ = try attachSessionStore()

        await vm.startNewChat()

        XCTAssertNil(vm.pendingHumanToolCallID)
    }

    func testSwitchingSessionDropsThePendingQuestion() async throws {
        let store = try attachSessionStore()
        let other = store.createSession(agentID: "test")

        await vm.switchToSession(other)

        XCTAssertNil(vm.pendingHumanToolCallID)
    }

    // MARK: - The agent's state while the question is open

    private var agentState: Agent.AgentState? {
        orchestrator.agents.first { $0.id == "test" }?.state
    }

    /// The turn behind the question has ended (the mock's stream runs on to
    /// its result), yet the agent reads as waiting on you — not idle.
    func testAskingPutsTheAgentInWaitingForHuman() {
        XCTAssertEqual(agentState, .waitingForHuman)
    }

    /// Answered, the turn it continues runs and ends: idle, not waiting.
    func testAnsweringReturnsTheAgentFromWaiting() async throws {
        await vm.respondToHuman(requestID: toolCallID, answer: answer)

        XCTAssertEqual(agentState, .idle)
    }

    /// An answer to a call the session has moved past answers nothing, so the
    /// agent is still waiting on the real one.
    func testAStrayAnswerLeavesTheAgentWaiting() async throws {
        await vm.respondToHuman(requestID: "ask-from-another-turn", answer: answer)

        XCTAssertEqual(agentState, .waitingForHuman)
    }

    func testClearingDoesNotLeaveTheAgentWaiting() async throws {
        await vm.clear()

        XCTAssertEqual(agentState, .idle)
    }

    func testRestartingDoesNotLeaveTheAgentWaiting() async throws {
        await vm.restart()

        XCTAssertEqual(agentState, .idle)
    }

    func testSwitchingSessionDoesNotLeaveTheAgentWaiting() async throws {
        let store = try attachSessionStore()
        let other = store.createSession(agentID: "test")

        await vm.switchToSession(other)

        XCTAssertEqual(agentState, .idle)
    }

    /// A message typed instead of an answer runs a turn — working while it
    /// runs — and the question is still open once it ends.
    func testATurnRunWhileTheQuestionIsOpenReturnsToWaiting() async throws {
        mock.events = [Self.doneResult()]
        let stream = orchestrator.send("something else first", to: "test")
        XCTAssertEqual(agentState, .working)
        for await _ in stream {}
        orchestrator.markTurnDone(agentID: "test")

        XCTAssertEqual(agentState, .waitingForHuman)
    }

    /// Stopping the agent's session — the sidebar's Stop, or a run replacing
    /// it — kills the call the question was asked from, so nothing waits on
    /// an answer any more; the agent is idle, and stays so once the chat
    /// lets go of the question.
    func testStoppingTheSessionDoesNotLeaveTheAgentWaiting() async throws {
        orchestrator.stopAgent("test")
        XCTAssertEqual(agentState, .idle)

        await vm.clear()
        XCTAssertEqual(agentState, .idle)
    }

    // MARK: - The rule, without a session

    func testTheTrackerShowsWaitingOverIdleButNotOverARunningTurn() {
        let tracker = PendingQuestionTracker()
        XCTAssertEqual(tracker.settle(.working, for: "a"), .working, "no question: the state as is")
        XCTAssertEqual(tracker.ask("a", current: .working), .waitingForHuman)
        XCTAssertEqual(tracker.settle(.idle, for: "a"), .waitingForHuman)
        XCTAssertEqual(tracker.settle(.working, for: "a"), .working)
        XCTAssertEqual(tracker.settle(.idle, for: "a"), .waitingForHuman)
        XCTAssertEqual(tracker.settle(.idle, for: "b"), .idle, "another agent is untouched")
        XCTAssertEqual(tracker.answer("a", current: .waitingForHuman), .idle)
        XCTAssertEqual(tracker.settle(.idle, for: "a"), .idle, "answered: no longer waiting")
        XCTAssertEqual(tracker.answer("a", current: .working), .working, "a second close changes nothing")

        _ = tracker.ask("a", current: .working)
        XCTAssertEqual(tracker.sessionEnded("a"), .idle)
        XCTAssertEqual(tracker.settle(.idle, for: "a"), .idle, "the session's end took the question with it")
    }

    // MARK: - A question still waiting is already on disk

    /// A store to save into, on a session that already carries a title: an
    /// untitled one would send `saveMessages` off to generate one.
    private func attachTitledSessionStore() throws -> (store: SessionStore, session: ChatSession) {
        let dir = try makeTemporaryDirectory(prefix: "kiteloop-ask-human-persist")
        let store = SessionStore(projectDir: dir)
        var session = store.createSession(agentID: "test")
        session.title = "Named"
        store.updateSession(session)
        vm.setupSessionStore(store)
        return (store, session)
    }

    func testThePendingQuestionIsOnDiskBeforeItIsAnswered() async throws {
        await vm.clear()
        let (store, session) = try attachTitledSessionStore()
        // The stream runs on past the question, the way the CLI leaves it
        // idling while it waits: the save under test is the one that happens
        // there, not the one at the end of the turn.
        mock.events = [.toolUse(id: toolCallID, name: "ask_human", input: "{\"question\": \"\(question)\"}")]
            + Array(repeating: StreamEvent.assistantText("."), count: 20)
            + [Self.doneResult()]

        vm.inputText = "start it"
        let sending = Task { await vm.send() }

        // The write is a detached task, and `isStreaming` is what says the turn
        // has not reached the boundary that would have saved anyway.
        try await eventually("the question on disk while the turn still waits") {
            vm.isStreaming && store.loadMessages(for: session).contains { message in
                if case .approval(let req) = message.content { return req.action == self.question }
                return false
            }
        }

        await sending.value
    }

    // MARK: - The bubble

    private func bubble(status: Message.ApprovalRequest.ApprovalStatus, isAnswerable: Bool) -> AskHumanBubble {
        AskHumanBubble(
            request: .init(id: toolCallID, action: question, tool: "ask_human", status: status),
            isAnswerable: isAnswerable,
            onRespond: { _ in }
        )
    }

    func testTheBubbleOffersAnAnswerOnlyForTheCallTheSessionAwaits() {
        XCTAssertTrue(bubble(status: .pending, isAnswerable: true).showsAnswerField)
        XCTAssertFalse(bubble(status: .pending, isAnswerable: false).showsAnswerField)
        XCTAssertFalse(bubble(status: .approved, isAnswerable: true).showsAnswerField)
    }

    // MARK: - The chat's filter

    private func approvalMessage(tool: String, status: Message.ApprovalRequest.ApprovalStatus) -> Message {
        Message(
            id: UUID(), timestamp: Date(), sender: .agent("dev"),
            content: .approval(.init(id: toolCallID, action: question, tool: tool, status: status))
        )
    }

    func testTheChatKeepsAnAnsweredQuestion() {
        XCTAssertTrue(ChatView.shouldDisplay(approvalMessage(tool: "ask_human", status: .approved)))
    }

    func testTheChatStillDropsADecidedPermissionRequest() {
        XCTAssertFalse(ChatView.shouldDisplay(approvalMessage(tool: "Bash", status: .approved)))
        XCTAssertFalse(ChatView.shouldDisplay(approvalMessage(tool: "Bash", status: .denied)))
    }

    func testTheChatShowsAPendingApprovalOfEitherKind() {
        XCTAssertTrue(ChatView.shouldDisplay(approvalMessage(tool: "ask_human", status: .pending)))
        XCTAssertTrue(ChatView.shouldDisplay(approvalMessage(tool: "Bash", status: .pending)))
    }
}
