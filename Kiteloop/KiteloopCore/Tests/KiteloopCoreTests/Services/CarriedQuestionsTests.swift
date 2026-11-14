import XCTest
@testable import KiteloopCore

/// Which question a chat on disk still has open, and what answering it says.
final class CarriedQuestionsTests: XCTestCase {

    private func asked(_ id: String = "tool-1", status: Message.ApprovalRequest.ApprovalStatus = .pending,
                       tool: String = "ask_human") -> Message {
        Message(id: UUID(), timestamp: .now, sender: .agent("Chief"),
                content: .approval(.init(id: id, action: "Ship on Friday?", tool: tool, status: status)))
    }

    private func choices(_ id: String = "req-2") -> Message {
        let input = #"{"questions":[{"question":"Who reviews?","header":"Reviewer","multiSelect":false,"options":[{"label":"A","description":""}]},{"question":"Split it?","header":"Split","multiSelect":false,"options":[]}]}"#
        return PermissionCards.card(for: PermissionPrompt.Request(id: id, toolName: "AskUserQuestion", input: input),
                                    subagent: nil, agentID: "Chief")
    }

    private func permission(_ id: String = "req-1") -> Message {
        PermissionCards.card(for: PermissionPrompt.Request(id: id, toolName: "Bash", input: #"{"command":"make"}"#),
                             subagent: nil, agentID: "Chief")
    }

    func testAChatThatEndsOnAnUnansweredQuestionCarriesIt() {
        XCTAssertEqual(CarriedQuestions.trailing(in: [.human("hi"), asked()]),
                       .init(id: "tool-1", asked: ["Ship on Friday?"], isChoices: false))
        XCTAssertEqual(CarriedQuestions.trailing(in: [choices()]),
                       .init(id: "req-2", asked: ["Who reviews?", "Split it?"], isChoices: true))
    }

    func testAQuestionWithAnythingAfterItOrAlreadyAnsweredIsNotCarried() {
        XCTAssertNil(CarriedQuestions.trailing(in: [asked(), .human("never mind")]))
        XCTAssertNil(CarriedQuestions.trailing(in: [asked(status: .approved)]))
        XCTAssertNil(CarriedQuestions.trailing(in: [asked(tool: "Bash")]))
        XCTAssertNil(CarriedQuestions.trailing(in: [permission()]), "a call waiting on leave died with its session")
        XCTAssertNil(CarriedQuestions.trailing(in: []))
    }

    func testEveryOtherOpenCardLapsesAndTheTrailingQuestionsStayOpen() {
        var messages = [permission(), choices("req-old"), choices()]

        let carried = CarriedQuestions.lapseAllButTrailing(in: &messages)

        XCTAssertEqual(carried?.id, "req-2")
        XCTAssertEqual(PermissionCards.openRequestIDs(in: messages), ["req-2"])
    }

    func testWithNothingToCarryEveryOpenCardLapses() {
        var messages = [choices(), permission()]

        XCTAssertNil(CarriedQuestions.lapseAllButTrailing(in: &messages))

        XCTAssertEqual(PermissionCards.openRequestIDs(in: messages), [])
    }

    func testATrailingAskHumanIsCarriedAndTheCardsBeforeItLapse() {
        var messages = [permission(), asked()]

        XCTAssertEqual(CarriedQuestions.lapseAllButTrailing(in: &messages)?.id, "tool-1")
        XCTAssertEqual(PermissionCards.openRequestIDs(in: messages), [])
    }

    func testTheReplyNamesWhatWasAskedBesideEachAnswer() {
        XCTAssertEqual(CarriedQuestions.reply(to: ["Ship on Friday?"], with: ["Yes, after the demo."]),
                       "Answering your earlier question — “Ship on Friday?”:\n\nYes, after the demo.")
        XCTAssertEqual(CarriedQuestions.reply(to: ["Who reviews?", "Split it?"], with: ["A", "No"]),
                       "Answering your earlier questions:\n\n- Who reviews? → A\n- Split it? → No")
    }
}
