import XCTest
@testable import KiteloopCore

/// The cards a session's prompts open, and what answering each sends back.
final class PermissionCardsTests: XCTestCase {

    private let offers = [
        PermissionPrompt.Suggestion(label: "Always allow Bash(make) in this project", json: #"{"type":"addRules"}"#)
    ]

    private func leave(_ id: String = "req-1", subagentTask: String? = nil) -> PermissionPrompt.Request {
        PermissionPrompt.Request(id: id, toolName: "Bash", input: #"{"command":"make"}"#, description: "Build",
                                 subagentTaskID: subagentTask, suggestions: offers)
    }

    private func card(_ request: PermissionPrompt.Request, subagent: String? = nil) -> Message {
        PermissionCards.card(for: request, subagent: subagent, agentID: "Builder")
    }

    private func permission(_ message: Message, file: StaticString = #filePath, line: UInt = #line) throws -> Message.PermissionRequest {
        guard case .permission(let request) = message.content else {
            XCTFail("not a permission card", file: file, line: line)
            throw CancellationError()
        }
        return request
    }

    // MARK: - Opening

    func testACallWaitingOnLeaveOpensAPermissionCard() throws {
        let message = card(leave(subagentTask: "task-9"), subagent: "Run the tests")
        XCTAssertEqual(message.sender, .agent("Builder"))
        let request = try permission(message)
        XCTAssertEqual(request.id, "req-1")
        XCTAssertEqual(request.toolName, "Bash")
        XCTAssertEqual(request.summary, "make")
        XCTAssertEqual(request.subagent, "Run the tests")
        XCTAssertEqual(request.question, "Run the tests — make")
        XCTAssertEqual(request.suggestions, offers)
        XCTAssertNil(request.answer)
        XCTAssertEqual(try permission(card(leave())).question, "make", "the agent's own call names nobody")
    }

    func testTheModelsQuestionsOpenAChoicesCard() throws {
        let input = """
        {"questions":[{"question":"Tea or coffee?","header":"Drink","multiSelect":false,\
        "options":[{"label":"Tea","description":"Leaves"},{"label":"Coffee","description":"Beans"}]},\
        {"question":"Which sizes?","header":"Size","multiSelect":true,"options":[{"label":"S"},{"label":"L"}]}]}
        """
        let message = card(PermissionPrompt.Request(id: "req-2", toolName: "AskUserQuestion", input: input, needsAnswer: true))
        guard case .choices(let asked) = message.content else { return XCTFail("not a choices card") }
        XCTAssertEqual(asked.id, "req-2")
        XCTAssertEqual(asked.questions.map(\.question), ["Tea or coffee?", "Which sizes?"])
        XCTAssertEqual(asked.questions[0].options, [.init(label: "Tea", description: "Leaves"), .init(label: "Coffee", description: "Beans")])
        XCTAssertEqual(asked.questions.map(\.multiSelect), [false, true])
        XCTAssertEqual(asked.text, "Tea or coffee?\nWhich sizes?")
        XCTAssertTrue(asked.isOpen)
    }

    func testAnOfferedPlanOpensAPlanCardThatRemembersItsRequest() {
        let input = #"{"plan":"1. Write it\n2. Test it","planFilePath":"/tmp/plan.md"}"#
        let message = card(PermissionPrompt.Request(id: "req-3", toolName: "ExitPlanMode", input: input, needsAnswer: true))
        guard case .plan(let plan) = message.content else { return XCTFail("not a plan card") }
        XCTAssertEqual(plan.text, "1. Write it\n2. Test it")
        XCTAssertEqual(plan.requestID, "req-3")
        XCTAssertEqual(plan.requestInput, input)
        XCTAssertNil(plan.answer)
    }

    func testTheNoticeNamesTheAgentAndTheQuestion() throws {
        let notice = try XCTUnwrap(PermissionCards.notice(for: card(leave()).content, agentName: "Builder"))
        XCTAssertEqual(notice.title, "Builder asks to use Bash")
        XCTAssertEqual(notice.body, "make")
        let plan = Message.Content.plan(Message.PlanProposal(text: "\n  \nFirst line\nSecond", requestID: "r"))
        XCTAssertEqual(PermissionCards.notice(for: plan, agentName: "Planner")?.body, "First line")
        XCTAssertNil(PermissionCards.notice(for: .text("hello"), agentName: "Builder"))
    }

    // MARK: - Answering a call

    func testAllowingOnceMarksTheCardAndHandsTheInputBack() throws {
        var messages = [card(leave())]
        XCTAssertEqual(PermissionCards.allow("req-1", in: &messages), .allow(input: #"{"command":"make"}"#))
        XCTAssertEqual(try permission(messages[0]).answer, .allowed)
        XCTAssertTrue(PermissionCards.openRequestIDs(in: messages).isEmpty)
    }

    func testAllowingAlwaysRemembersTheOfferNamed() throws {
        var messages = [card(leave())]
        XCTAssertEqual(PermissionCards.allow("req-1", remembering: 0, in: &messages),
                       .allow(input: #"{"command":"make"}"#, remembering: [#"{"type":"addRules"}"#]))
        XCTAssertEqual(try permission(messages[0]).answer, .allowedAlways)
    }

    func testAnOfferTheCardDoesNotMakeAnswersNothing() throws {
        var messages = [card(leave())]
        XCTAssertNil(PermissionCards.allow("req-1", remembering: 3, in: &messages))
        XCTAssertNil(try permission(messages[0]).answer, "the card still waits")
        XCTAssertEqual(PermissionCards.openRequestIDs(in: messages), ["req-1"])
    }

    func testRefusingTellsTheModelToStop() throws {
        var messages = [card(leave())]
        XCTAssertEqual(PermissionCards.deny("req-1", in: &messages), .deny(message: PermissionPrompt.declined))
        XCTAssertEqual(try permission(messages[0]).answer, .denied)
    }

    func testACardIsAnsweredOnce() {
        var messages = [card(leave())]
        XCTAssertNotNil(PermissionCards.deny("req-1", in: &messages))
        XCTAssertNil(PermissionCards.allow("req-1", in: &messages), "a second answer, from a phone or the Mac, is nothing")
        XCTAssertNil(PermissionCards.deny("req-1", in: &messages))
        XCTAssertNil(PermissionCards.allow("req-other", in: &messages), "nor is an answer to a card that is not there")
    }

    // MARK: - Answering the model's questions

    private func questions() -> Message {
        let input = #"{"questions":[{"question":"Tea or coffee?","options":[{"label":"Tea"},{"label":"Coffee"}]},{"question":"Size?"}]}"#
        return card(PermissionPrompt.Request(id: "req-2", toolName: "AskUserQuestion", input: input))
    }

    func testAnswersGoBackKeyedByTheirQuestions() throws {
        var messages = [questions()]
        guard case .allow(let input, let remembering) = PermissionCards.answer("req-2", with: ["Coffee", "Large, please"], in: &messages) else {
            return XCTFail("the answers were refused")
        }
        XCTAssertTrue(remembering.isEmpty)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any])
        XCTAssertEqual(json["answers"] as? [String: String], ["Tea or coffee?": "Coffee", "Size?": "Large, please"])
        XCTAssertEqual((json["questions"] as? [[String: Any]])?.count, 2, "the questions go back with their answers")
        guard case .choices(let asked) = messages[0].content else { return XCTFail("not a choices card") }
        XCTAssertEqual(asked.answers, ["Coffee", "Large, please"])
        XCTAssertFalse(asked.isOpen)
    }

    func testAnswersThatDoNotFitTheQuestionsAreRefusedAndTheCardStillWaits() {
        var messages = [questions()]
        XCTAssertNil(PermissionCards.answer("req-2", with: ["Coffee"], in: &messages), "one answer for two questions")
        XCTAssertNil(PermissionCards.answer("req-2", with: ["Coffee", "  "], in: &messages), "a blank answer")
        XCTAssertNil(PermissionCards.allow("req-2", in: &messages), "a questions card is not allowed like a call")
        XCTAssertEqual(PermissionCards.openRequestIDs(in: messages), ["req-2"])
    }

    // MARK: - Answering a plan

    private func offeredPlan() -> Message {
        card(PermissionPrompt.Request(id: "req-3", toolName: "ExitPlanMode", input: #"{"plan":"Do it","planFilePath":"/tmp/p.md"}"#))
    }

    func testApprovingAnOfferedPlanAllowsItInTheChosenMode() throws {
        var messages = [offeredPlan()]
        let answered = try XCTUnwrap(PermissionCards.answerPlan(messages[0].id, with: .approveAcceptEdits, feedback: "", in: &messages))
        XCTAssertEqual(answered.requestID, "req-3")
        guard case .allow(let input, let remembering) = answered.decision else { return XCTFail("not allowed") }
        XCTAssertEqual(input, #"{"plan":"Do it","planFilePath":"/tmp/p.md"}"#, "the plan goes back as it was offered")
        let mode = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(remembering.first).utf8)) as? [String: String])
        XCTAssertEqual(mode, ["type": "setMode", "mode": "acceptEdits", "destination": "session"])
        guard case .plan(let plan) = messages[0].content else { return XCTFail("not a plan") }
        XCTAssertEqual(plan.answer, .approveAcceptEdits)
        XCTAssertTrue(PermissionCards.openRequestIDs(in: messages).isEmpty)
    }

    func testKeepPlanningRefusesThePlanWithWhatShouldChange() throws {
        var messages = [offeredPlan()]
        XCTAssertEqual(PermissionCards.answerPlan(messages[0].id, with: .keepPlanning, feedback: "Smaller steps", in: &messages)?.decision,
                       .deny(message: "Smaller steps"))
        messages = [offeredPlan()]
        XCTAssertEqual(PermissionCards.answerPlan(messages[0].id, with: .keepPlanning, feedback: "", in: &messages)?.decision,
                       .deny(message: PermissionPrompt.declined))
    }

    func testAPlanReadOffTheTranscriptIsNotAnsweredThisWay() {
        var messages = [Message(id: UUID(), timestamp: .now, sender: .agent("Planner"), content: .plan(Message.PlanProposal(text: "Do it")))]
        XCTAssertNil(PermissionCards.answerPlan(messages[0].id, with: .approveAuto, feedback: "", in: &messages))
        guard case .plan(let plan) = messages[0].content else { return XCTFail("not a plan") }
        XCTAssertNil(plan.answer, "and it is left for the older way to answer")
        XCTAssertTrue(PermissionCards.openRequestIDs(in: messages).isEmpty, "it is no request the session waits on")
    }

    // MARK: - Lapsing

    func testAQuestionTakenBackLapsesOnlyItsOwnCard() throws {
        var messages = [card(leave("req-1")), card(leave("req-9")), questions()]
        XCTAssertTrue(PermissionCards.lapse("req-9", in: &messages))
        XCTAssertEqual(try permission(messages[1]).answer, .lapsed)
        XCTAssertEqual(PermissionCards.openRequestIDs(in: messages), ["req-1", "req-2"])
        XCTAssertFalse(PermissionCards.lapse("req-9", in: &messages), "a card already closed does not change")
    }

    func testASessionGoneLapsesEveryOpenCardAndLeavesAnsweredOnesAlone() throws {
        var messages = [card(leave("req-1")), questions(), offeredPlan(), card(leave("req-4"))]
        XCTAssertNotNil(PermissionCards.allow("req-4", in: &messages))
        XCTAssertTrue(PermissionCards.lapse(in: &messages))
        XCTAssertEqual(try permission(messages[0]).answer, .lapsed)
        guard case .choices(let asked) = messages[1].content, case .plan(let plan) = messages[2].content else {
            return XCTFail("the cards changed kind")
        }
        XCTAssertTrue(asked.lapsed)
        XCTAssertFalse(asked.isOpen)
        XCTAssertEqual(plan.answer, .keepPlanning, "a plan nobody approved is one still being planned")
        XCTAssertEqual(try permission(messages[3]).answer, .allowed)
        XCTAssertFalse(PermissionCards.lapse(in: &messages))
    }

    // MARK: - Refusals the person made

    func testARefusalMadeOnACardIsToldApartFromOneTheSessionMadeItself() {
        var messages = [card(leave("req-1")), card(leave("req-2"))]
        XCTAssertFalse(PermissionCards.wasRefusedOnACard(toolName: "Bash", detail: "make", in: messages), "still open")
        XCTAssertNotNil(PermissionCards.allow("req-1", in: &messages))
        XCTAssertFalse(PermissionCards.wasRefusedOnACard(toolName: "Bash", detail: "make", in: messages), "allowed is not refused")
        XCTAssertNotNil(PermissionCards.deny("req-2", in: &messages))
        XCTAssertTrue(PermissionCards.wasRefusedOnACard(toolName: "Bash", detail: "make", in: messages))
        XCTAssertTrue(PermissionCards.wasRefusedOnACard(toolName: "Bash", detail: "", in: messages), "a refusal that names no target")
        XCTAssertFalse(PermissionCards.wasRefusedOnACard(toolName: "Bash", detail: "rm -rf build", in: messages), "another command")
        XCTAssertFalse(PermissionCards.wasRefusedOnACard(toolName: "Write", detail: "make", in: messages), "another tool")

        var lapsed = [card(leave())]
        PermissionCards.lapse(in: &lapsed)
        XCTAssertTrue(PermissionCards.wasRefusedOnACard(toolName: "Bash", detail: "make", in: lapsed), "taken back counts")
    }

    // MARK: - On disk

    func testTheCardsSurviveBeingSaved() throws {
        var messages = [card(leave()), questions(), offeredPlan()]
        XCTAssertNotNil(PermissionCards.allow("req-1", remembering: 0, in: &messages))
        let decoded = try JSONDecoder().decode([Message].self, from: JSONEncoder().encode(messages))
        XCTAssertEqual(try permission(decoded[0]), try permission(messages[0]))
        guard case .choices(let asked) = decoded[1].content, case .plan(let plan) = decoded[2].content else {
            return XCTFail("a card came back as another kind")
        }
        XCTAssertEqual(asked.questions.count, 2)
        XCTAssertEqual(plan.requestID, "req-3")
        XCTAssertEqual(PermissionCards.openRequestIDs(in: decoded), ["req-2", "req-3"])
    }

    func testAPlanSavedBeforeRequestsWereKeptStillLoads() throws {
        let saved = #"[{"id":"\#(UUID().uuidString)","timestamp":0,"sender":{"type":"system"},"content":{"type":"plan","plan":{"text":"Old"}}}]"#
        let decoded = try JSONDecoder().decode([Message].self, from: Data(saved.utf8))
        guard case .plan(let plan) = decoded[0].content else { return XCTFail("not a plan") }
        XCTAssertEqual(plan.text, "Old")
        XCTAssertNil(plan.requestID)
    }
}
