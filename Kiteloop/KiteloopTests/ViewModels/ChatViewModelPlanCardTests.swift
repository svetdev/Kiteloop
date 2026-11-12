import XCTest
import KiteloopCore
@testable import Kiteloop

/// A `plan`-mode agent that writes its plan under `~/.claude/plans/` ends the
/// turn with that plan as a card, and the card's answer drives the agent on.
@MainActor
final class ChatViewModelPlanCardTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = try makeTemporaryDirectory(prefix: "kiteloop-plan-card")
    }

    // MARK: - Helpers

    private func makeVM(
        permissionMode: String, events: [StreamEvent]
    ) async throws -> (ChatViewModel, MockAgentRuntime, Orchestrator) {
        let mock = MockAgentRuntime()
        mock.events = events
        let orchestrator = Orchestrator(runtime: mock)
        orchestrator.configureNotifications(notificationsURL: tempDir.appending(path: "notifications.log"))
        orchestrator.addAgent(Agent(
            id: "planner", name: "Planner", model: "sonnet",
            systemPrompt: "", tools: [],
            denied: [], permissionMode: permissionMode, state: .idle
        ))
        try await orchestrator.startAgent("planner", cwd: tempDir)
        let vm = ChatViewModel(agentID: "planner", projectURL: tempDir, orchestrator: orchestrator)
        return (vm, mock, orchestrator)
    }

    private var planPath: String {
        PlanProposalDetector.userPlansDirectory.appending(path: "x.md").path
    }

    private func writeEvent(path: String, content: String) throws -> StreamEvent {
        let input = try JSONSerialization.data(withJSONObject: ["file_path": path, "content": content])
        return .toolUse(id: "write-1", name: "Write", input: String(decoding: input, as: UTF8.self))
    }

    private func turn(writing path: String, content: String, sessionID: String = "s-plan") throws -> [StreamEvent] {
        [
            try writeEvent(path: path, content: content),
            .toolResult(id: "write-1", output: "File created successfully"),
            .assistantText("The plan is written."),
            .result(.init(
                text: "The plan is written.", costUSD: 0.001, durationMs: 10,
                inputTokens: 1, outputTokens: 1,
                cacheCreationInputTokens: 0, cacheReadInputTokens: 0,
                sessionID: sessionID, permissionDenials: []
            )),
        ]
    }

    private func planCards(_ vm: ChatViewModel) -> [(id: UUID, plan: Message.PlanProposal)] {
        vm.messages.compactMap { message in
            if case .plan(let plan) = message.content { return (message.id, plan) }
            return nil
        }
    }

    /// A plan agent's turn that wrote a plan, with the card it ended on.
    private func plannedTurn(
        sessionStore: SessionStore? = nil
    ) async throws -> (ChatViewModel, MockAgentRuntime, Orchestrator, UUID) {
        let (vm, mock, orchestrator) = try await makeVM(
            permissionMode: "plan", events: turn(writing: planPath, content: "# Plan\n\n1. Build it"))
        // Attached before the turn, as the app does: attaching a store loads
        // the chat it opens, which would drop a card already on screen.
        if let sessionStore { vm.setupSessionStore(sessionStore) }
        vm.inputText = "plan the feature"
        await vm.send()
        let card = try XCTUnwrap(planCards(vm).first, "The turn should end with a plan card")
        mock.lastStartedAgent = nil
        mock.lastStrategy = nil
        return (vm, mock, orchestrator, card.id)
    }

    private func permissionMode(in orchestrator: Orchestrator) -> String? {
        orchestrator.agents.first { $0.id == "planner" }?.permissionMode
    }

    // MARK: - Detection

    func testAPlanAgentsTurnThatWritesAPlanEndsWithTheCard() async throws {
        let (vm, _, _, _) = try await plannedTurn()

        let cards = planCards(vm)
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards.first?.plan.text, "# Plan\n\n1. Build it")
        XCTAssertNil(cards.first?.plan.answer)
        guard case .plan = vm.messages.last?.content else {
            return XCTFail("The card should come after the turn's own messages")
        }
    }

    func testTheSameWriteOnAnAutoAgentPostsNoCard() async throws {
        let (vm, _, _) = try await makeVM(permissionMode: "auto", events: turn(writing: planPath, content: "# Plan"))
        vm.inputText = "plan the feature"
        await vm.send()

        XCTAssertTrue(planCards(vm).isEmpty)
    }

    func testAWriteElsewhereOnAPlanAgentPostsNoCard() async throws {
        let elsewhere = tempDir.appending(path: "plan.md").path
        let (vm, _, _) = try await makeVM(permissionMode: "plan", events: turn(writing: elsewhere, content: "# Plan"))
        vm.inputText = "plan the feature"
        await vm.send()

        XCTAssertTrue(planCards(vm).isEmpty)
    }

    // MARK: - Answers

    /// A plan written to a file, with no request to answer, is approved the
    /// older way — by `/mode`. Plan asks and Auto approves the agent's tools,
    /// so that takes a new process, on the same conversation.
    func testApproveAndBuildAutoRestartsInAutoOnTheSameConversationAndSendsTheApproval() async throws {
        let (vm, mock, orchestrator, cardID) = try await plannedTurn()

        await vm.answerPlan(messageID: cardID, with: .approveAuto)

        XCTAssertEqual(permissionMode(in: orchestrator), "auto")
        XCTAssertEqual(mock.lastStartedAgent?.permissionMode, "auto", "Auto is a spawn on other terms")
        XCTAssertEqual(mock.lastSessionOptions?.asksBeforeListedTools, false)
        guard case .resume = mock.lastStrategy else { return XCTFail("The restart should resume the conversation") }
        XCTAssertEqual(mock.lastSentMessage, ChatViewModel.planApprovalMessage)
        XCTAssertEqual(planCards(vm).first?.plan.answer, .approveAuto)
    }

    func testApproveAndBuildAcceptEditsSwitchesToAcceptEditsOnTheSameSessionAndSendsTheApproval() async throws {
        let (vm, mock, orchestrator, cardID) = try await plannedTurn()

        await vm.answerPlan(messageID: cardID, with: .approveAcceptEdits)

        assertApproved(vm, mock, orchestrator, mode: "acceptEdits", answer: .approveAcceptEdits)
    }

    private func assertApproved(_ vm: ChatViewModel, _ mock: MockAgentRuntime, _ orchestrator: Orchestrator,
                                mode: String, answer: Message.PlanProposal.Answer,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(permissionMode(in: orchestrator), mode, file: file, line: line)
        XCTAssertNil(mock.lastStartedAgent, "Approving moves the running session; nothing restarts", file: file, line: line)
        XCTAssertTrue(mock.controlLines.contains { $0.contains("set_permission_mode") && $0.contains("\"\(mode)\"") },
                      "The session should be told its new mode", file: file, line: line)
        XCTAssertEqual(mock.lastSentMessage, ChatViewModel.planApprovalMessage, file: file, line: line)
        XCTAssertTrue(vm.messages.contains { message in
            if case .text(let text) = message.content { return message.sender == .human && text == ChatViewModel.planApprovalMessage }
            return false
        }, "The approval should read as your message", file: file, line: line)
        XCTAssertEqual(planCards(vm).first?.plan.answer, answer, "The card should read the choice", file: file, line: line)
    }

    func testKeepPlanningChangesNothingAndSendsNothing() async throws {
        let (vm, mock, orchestrator, cardID) = try await plannedTurn()
        let sent = mock.sentMessages.count

        await vm.answerPlan(messageID: cardID, with: .keepPlanning)

        XCTAssertEqual(permissionMode(in: orchestrator), "plan")
        XCTAssertNil(mock.lastStartedAgent, "Keep planning must not restart the agent")
        XCTAssertNil(mock.lastStrategy)
        XCTAssertEqual(mock.sentMessages.count, sent, "Keep planning must send nothing")
        XCTAssertEqual(planCards(vm).first?.plan.answer, .keepPlanning)
    }

    func testKeepPlanningWithFeedbackSendsExactlyThatAsYourMessage() async throws {
        let (vm, mock, orchestrator, cardID) = try await plannedTurn()
        let sent = mock.sentMessages.count

        await vm.answerPlan(messageID: cardID, with: .keepPlanning, feedback: "  use SQLite instead\n")

        XCTAssertEqual(mock.sentMessages.dropFirst(sent).map(\.message), ["use SQLite instead"],
                       "Only the feedback should be sent, with no /mode before it")
        XCTAssertEqual(permissionMode(in: orchestrator), "plan")
        XCTAssertNil(mock.lastStartedAgent, "Keep planning must not restart the agent")
        XCTAssertTrue(vm.messages.contains { message in
            if case .text(let text) = message.content { return message.sender == .human && text == "use SQLite instead" }
            return false
        }, "The feedback should read as your message")
        XCTAssertEqual(planCards(vm).first?.plan.answer, .keepPlanning)
    }

    func testKeepPlanningWithEmptyOrBlankFeedbackSendsNothing() async throws {
        for feedback in ["", " \n\t "] {
            let (vm, mock, orchestrator, cardID) = try await plannedTurn()
            let sent = mock.sentMessages.count

            await vm.answerPlan(messageID: cardID, with: .keepPlanning, feedback: feedback)

            XCTAssertEqual(mock.sentMessages.count, sent, "\(feedback.debugDescription) must send nothing")
            XCTAssertEqual(permissionMode(in: orchestrator), "plan")
            XCTAssertEqual(vm.queuedMessageCount, 0)
            XCTAssertEqual(planCards(vm).first?.plan.answer, .keepPlanning)
        }
    }

    func testReturnAnswersTheCardOnlyWithTextInTheField() {
        XCTAssertFalse(PlanCard.returnAnswers(""))
        XCTAssertFalse(PlanCard.returnAnswers("   "))
        XCTAssertFalse(PlanCard.returnAnswers("\n\n"))
        XCTAssertTrue(PlanCard.returnAnswers("  split step 2 \n"))
    }

    func testKeepPlanningWithFeedbackWaitsOutARunningTurn() async throws {
        let (vm, mock, _, cardID) = try await plannedTurn()
        mock.events = replyTurn()
        let sent = mock.sentMessages.count
        mock.startUnpromptedTurn((1...6).map { StreamEvent.assistantText(" part \($0)") } + replyTurn().suffix(1))
        try await eventually("the unprompted turn is streaming") { vm.isStreaming }

        await vm.answerPlan(messageID: cardID, with: .keepPlanning, feedback: "use SQLite instead")

        XCTAssertEqual(vm.queuedMessageCount, 1)
        XCTAssertEqual(mock.sentMessages.count, sent, "Not sent while the turn runs")
        XCTAssertEqual(planCards(vm).first?.plan.answer, .keepPlanning)
        try await eventually("the feedback sent once the turn ended") {
            mock.sentMessages.dropFirst(sent).map(\.message) == ["use SQLite instead"]
        }
        XCTAssertEqual(vm.queuedMessageCount, 0)
    }

    func testAnAnsweredCardCannotBeAnsweredAgain() async throws {
        let (vm, mock, orchestrator, cardID) = try await plannedTurn()
        await vm.answerPlan(messageID: cardID, with: .keepPlanning)

        await vm.answerPlan(messageID: cardID, with: .approveAuto)

        XCTAssertEqual(permissionMode(in: orchestrator), "plan")
        XCTAssertNil(mock.lastStartedAgent)
        XCTAssertEqual(planCards(vm).first?.plan.answer, .keepPlanning)
    }

    // MARK: - Moving past a card

    /// A turn that answers in text and writes no plan.
    private func replyTurn() -> [StreamEvent] {
        [
            .assistantText("Noted."),
            .result(.init(
                text: "Noted.", costUSD: 0.001, durationMs: 10,
                inputTokens: 1, outputTokens: 1,
                cacheCreationInputTokens: 0, cacheReadInputTokens: 0,
                sessionID: "s-plan", permissionDenials: []
            )),
        ]
    }

    func testATypedMessageClosesTheOpenCardSoItCanNoLongerBeApproved() async throws {
        let (vm, mock, orchestrator, cardID) = try await plannedTurn()
        mock.events = replyTurn()
        vm.inputText = "use SQLite, not JSON"
        await vm.send()
        XCTAssertEqual(planCards(vm).first?.plan.answer, .keepPlanning)
        let sent = mock.sentMessages.count

        await vm.answerPlan(messageID: cardID, with: .approveAuto)

        XCTAssertEqual(permissionMode(in: orchestrator), "plan")
        XCTAssertNil(mock.lastStartedAgent)
        XCTAssertEqual(mock.sentMessages.count, sent, "A closed card must send no approval")
        XCTAssertEqual(planCards(vm).first?.plan.answer, .keepPlanning)
    }

    func testANewerPlanClosesTheOlderCardAndOnlyTheNewestCanBeApproved() async throws {
        let (vm, mock, orchestrator, firstID) = try await plannedTurn()
        mock.events = try turn(writing: planPath, content: "# Plan\n\n1. Build it with SQLite")
        vm.inputText = "use SQLite, not JSON"
        await vm.send()

        let cards = planCards(vm)
        XCTAssertEqual(cards.count, 2)
        XCTAssertEqual(cards.first?.id, firstID)
        XCTAssertEqual(cards.first?.plan.answer, .keepPlanning)
        let second = try XCTUnwrap(cards.last)
        XCTAssertNil(second.plan.answer)
        mock.lastStartedAgent = nil
        mock.lastStrategy = nil

        await vm.answerPlan(messageID: second.id, with: .approveAuto)

        XCTAssertEqual(permissionMode(in: orchestrator), "auto")
        XCTAssertEqual(mock.lastSentMessage, ChatViewModel.planApprovalMessage)
        XCTAssertEqual(planCards(vm).last?.plan.answer, .approveAuto)
    }

    func testAPlanRevisedWithAnEditComesBackAsANewCard() async throws {
        let (vm, mock, _, firstID) = try await plannedTurn()
        await vm.answerPlan(messageID: firstID, with: .keepPlanning)
        let input = try JSONSerialization.data(withJSONObject: [
            "file_path": planPath, "old_string": "Build it", "new_string": "Build it with SQLite",
        ])
        mock.events = [
            .toolUse(id: "edit-1", name: "Edit", input: String(decoding: input, as: UTF8.self)),
            .toolResult(id: "edit-1", output: "The file has been updated successfully"),
        ] + replyTurn()
        vm.inputText = "use SQLite, not JSON"
        await vm.send()

        let cards = planCards(vm)
        XCTAssertEqual(cards.count, 2)
        XCTAssertEqual(cards.first?.plan.answer, .keepPlanning)
        XCTAssertEqual(cards.last?.plan.text, "# Plan\n\n1. Build it with SQLite")
        XCTAssertNil(cards.last?.plan.answer)
    }

    func testASlashCommandLeavesTheCardOpen() async throws {
        let (vm, _, _, _) = try await plannedTurn()
        vm.inputText = "/cost"
        await vm.send()

        XCTAssertNil(planCards(vm).first?.plan.answer)
    }


    /// The inbox once the card's notice has landed: the file happens on a
    /// `Task`, so a test that answered before it landed would resolve nothing.
    private func inboxHoldingThePlan(_ orchestrator: Orchestrator) async throws -> NotificationStore {
        let store = try XCTUnwrap(orchestrator.notificationStore)
        try await eventually("the plan notice filed") {
            await store.pending().contains { $0.type == .question && $0.agentID == "planner" }
        }
        return store
    }

    func testAPostedCardFilesAQuestionNoticeForItsAgent() async throws {
        let (vm, _, orchestrator, _) = try await plannedTurn()
        let store = try await inboxHoldingThePlan(orchestrator)

        let pending = await store.pending()
        XCTAssertEqual(pending.count, 1)
        let notice = try XCTUnwrap(pending.first)
        XCTAssertTrue(notice.title.contains("plan ready"), notice.title)
        XCTAssertEqual(notice.body, "# Plan")
        XCTAssertEqual(notice.projectPath, vm.projectURL.path(percentEncoded: false))
    }

    func testATurnThatPostsNoCardFilesNoNotice() async throws {
        let (vm, _, orchestrator) = try await makeVM(permissionMode: "auto", events: turn(writing: planPath, content: "# Plan"))
        vm.inputText = "plan the feature"
        await vm.send()
        // A notice filed after the turn lands after anything the turn filed.
        orchestrator.notify(agentID: "other", type: .event, title: "Marker", body: "")
        let store = try XCTUnwrap(orchestrator.notificationStore)
        try await eventually("the marker filed") { await store.pending().contains { $0.agentID == "other" } }

        let pending = await store.pending()
        XCTAssertFalse(pending.contains { $0.agentID == "planner" })
    }

    func testEveryAnswerResolvesTheNotice() async throws {
        for answer in [Message.PlanProposal.Answer.approveAuto, .approveAcceptEdits, .keepPlanning] {
            // A directory per answer, so each inbox starts empty.
            tempDir = try makeTemporaryDirectory(prefix: "kiteloop-plan-card")
            let (vm, _, orchestrator, cardID) = try await plannedTurn()
            let store = try await inboxHoldingThePlan(orchestrator)

            await vm.answerPlan(messageID: cardID, with: answer)

            try await eventually("the plan notice resolved by \(answer)") {
                await store.pending().isEmpty
            }
            let resolved = await store.resolved()
            XCTAssertEqual(resolved.map(\.agentID), ["planner"], "\(answer)")
        }
    }

    func testAnsweringAnAnsweredCardAgainResolvesNothingMore() async throws {
        let (vm, _, orchestrator, cardID) = try await plannedTurn()
        let store = try await inboxHoldingThePlan(orchestrator)
        await vm.answerPlan(messageID: cardID, with: .keepPlanning)
        try await eventually("the plan notice resolved") { await store.pending().isEmpty }
        await store.add(NotificationItem(agentID: "planner", type: .question,
                                         title: "Planner needs input", body: "Which branch?"))

        await vm.answerPlan(messageID: cardID, with: .approveAuto)
        // A notice filed after the answer lands after anything the answer did.
        orchestrator.notify(agentID: "other", type: .event, title: "Marker", body: "")
        try await eventually("the marker filed") { await store.pending().contains { $0.agentID == "other" } }

        let pending = await store.pending()
        XCTAssertEqual(pending.map(\.agentID).sorted(), ["other", "planner"],
                       "The second answer must neither file nor resolve a notice")
        let resolved = await store.resolved()
        XCTAssertEqual(resolved.count, 1)
    }

    // MARK: - Waiting on you

    private func agentState(in orchestrator: Orchestrator) -> Agent.AgentState? {
        orchestrator.agents.first { $0.id == "planner" }?.state
    }

    func testAnOpenCardHasTheAgentWaitingOnYou() async throws {
        let (vm, _, orchestrator, _) = try await plannedTurn()

        XCTAssertTrue(vm.hasOpenPlanCard)
        XCTAssertEqual(agentState(in: orchestrator), .waitingForHuman)
    }

    func testEveryAnswerStopsTheAgentWaiting() async throws {
        for answer in [Message.PlanProposal.Answer.approveAuto, .approveAcceptEdits, .keepPlanning] {
            let (vm, _, orchestrator, cardID) = try await plannedTurn()

            await vm.answerPlan(messageID: cardID, with: answer)

            XCTAssertFalse(vm.hasOpenPlanCard, "\(answer)")
            XCTAssertNotEqual(agentState(in: orchestrator), .waitingForHuman, "\(answer)")
        }
    }

    func testATypedMessageStopsTheAgentWaiting() async throws {
        let (vm, mock, orchestrator, _) = try await plannedTurn()
        mock.events = replyTurn()
        vm.inputText = "use SQLite, not JSON"
        await vm.send()

        XCTAssertFalse(vm.hasOpenPlanCard)
        XCTAssertNotEqual(agentState(in: orchestrator), .waitingForHuman)
    }

    func testANewerPlanKeepsTheAgentWaitingOnTheNewCard() async throws {
        let (vm, mock, orchestrator, _) = try await plannedTurn()
        mock.events = try turn(writing: planPath, content: "# Plan\n\n1. Build it with SQLite")
        vm.inputText = "use SQLite, not JSON"
        await vm.send()
        let newest = try XCTUnwrap(planCards(vm).last)

        XCTAssertEqual(agentState(in: orchestrator), .waitingForHuman)

        await vm.answerPlan(messageID: newest.id, with: .keepPlanning)

        XCTAssertNotEqual(agentState(in: orchestrator), .waitingForHuman)
    }

    func testClosingTheCardWhileAQuestionIsPendingLeavesTheAgentWaiting() async throws {
        var events = try turn(writing: planPath, content: "# Plan\n\n1. Build it")
        events.insert(.toolUse(id: "ask-1", name: "ask_human", input: "{\"question\": \"Which branch?\"}"),
                      at: events.count - 1)
        let (vm, _, orchestrator) = try await makeVM(permissionMode: "plan", events: events)
        vm.inputText = "plan the feature"
        await vm.send()
        let card = try XCTUnwrap(planCards(vm).first)
        XCTAssertEqual(vm.pendingHumanToolCallID, "ask-1")

        await vm.answerPlan(messageID: card.id, with: .keepPlanning)

        XCTAssertFalse(vm.hasOpenPlanCard)
        XCTAssertEqual(agentState(in: orchestrator), .waitingForHuman)
    }

    // MARK: - Persistence

    func testAnAnsweredCardIsSavedWithItsAnswer() async throws {
        let store = SessionStore(projectDir: try makeTemporaryDirectory(prefix: "kiteloop-plan-card-sessions"))
        var session = store.createSession(agentID: "planner")
        session.title = "Named"
        store.updateSession(session)
        let (vm, _, _, cardID) = try await plannedTurn(sessionStore: store)

        await vm.answerPlan(messageID: cardID, with: .keepPlanning)

        try await eventually("the answered card on disk") {
            store.loadMessageTail(for: session, limit: 500).messages.contains { message in
                if case .plan(let plan) = message.content { return plan.answer == .keepPlanning }
                return false
            }
        }
    }
}
