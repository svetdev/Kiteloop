import XCTest
@testable import KiteloopMobile

/// The cards a session's prompts open on the phone: a call waiting on leave
/// to run, and the model's own questions with their choices.
final class PromptCardsTests: XCTestCase {

    private func message(_ json: String) throws -> TranscriptMessage {
        try JSONDecoder().decode(TranscriptMessage.self, from: Data(json.utf8))
    }

    // MARK: - Permission

    func testAnOpenPermissionBecomesACardWithItsRequestAndOffers() throws {
        let line = #"{"id":"m1","sender":"Builder","kind":"permission","text":"make test","at":"x","permission":{"request":"req-1","open":true,"tool":"Bash","always":["Always allow Bash(make test) in this project"]}}"#

        let row = try XCTUnwrap(TranscriptRow.rows(from: [try message(line)]).first)

        guard case .permission(let text, let state) = row.kind else { return XCTFail("a permission row") }
        XCTAssertEqual(text, "make test")
        XCTAssertEqual(state.request, "req-1")
        XCTAssertEqual(state.open, true)
        XCTAssertEqual(state.always, ["Always allow Bash(make test) in this project"])
        XCTAssertEqual(PermissionCardView.title(agentName: "Builder", state: state), "Builder asks to use Bash")
    }

    func testASubagentsCardNamesItsTask() throws {
        let line = #"{"id":"m1","kind":"permission","text":"Run the tests — make test","permission":{"request":"r","open":true,"tool":"Bash","always":[],"subagent":"Run the tests"}}"#
        guard case .permission(_, let state) = try XCTUnwrap(TranscriptRow.rows(from: [try message(line)]).first).kind else {
            return XCTFail("a permission row")
        }
        XCTAssertEqual(PermissionCardView.title(agentName: "Builder", state: state),
                       "Builder’s subagent “Run the tests” asks to use Bash")
    }

    func testAnAnsweredCardReadsWhatWasChosen() throws {
        let line = #"{"id":"m1","kind":"permission","text":"make","permission":{"request":"r","open":false,"tool":"Bash","always":[],"answer":"denied"}}"#
        guard case .permission(_, let state) = try XCTUnwrap(TranscriptRow.rows(from: [try message(line)]).first).kind else {
            return XCTFail("a permission row")
        }
        XCTAssertEqual(PermissionCardView.title(agentName: "Builder", state: state), "Builder asked to use Bash")
        XCTAssertEqual(PermissionCardView.answerLabel(state.answer), "Denied")
        XCTAssertFalse(PermissionCardView.wasAllowed(state.answer))
        XCTAssertEqual(PermissionCardView.answerLabel("allowed"), "Allowed once")
        XCTAssertEqual(PermissionCardView.answerLabel("allowedAlways"), "Allowed, and remembered")
        XCTAssertTrue(PermissionCardView.wasAllowed("allowedAlways"))
        XCTAssertEqual(PermissionCardView.answerLabel("lapsed"), "No longer waiting on an answer")
        XCTAssertEqual(PermissionCardView.answerLabel("something-new"), "Answered")
    }

    func testACardCarriesTheCallsTextFieldsAndOnlyWhatChangedIsSent() throws {
        let line = #"{"id":"m1","kind":"permission","text":"make","permission":{"request":"r","open":true,"tool":"Bash","always":[],"fields":[{"name":"command","value":"make"},{"name":"description","value":"Build"}],"edited":false}}"#
        guard case .permission(let text, let state) = try XCTUnwrap(TranscriptRow.rows(from: [try message(line)]).first).kind else {
            return XCTFail("a permission row")
        }
        let fields = try XCTUnwrap(state.fields)
        XCTAssertEqual(fields.map(\.name), ["command", "description"])
        XCTAssertEqual(PermissionCardView.edits(from: ["command": "make", "description": "Build"], over: fields), [:])
        XCTAssertEqual(PermissionCardView.edits(from: ["command": "make test", "other": "x"], over: fields), ["command": "make test"])
        XCTAssertEqual(PermissionCardView.shown(text: text, state: state), "make")
    }

    func testACardAllowedRewordedReadsAsItWasSent() throws {
        let one = PermissionState(request: "r", open: false, answer: "allowed",
                                  fields: [PermissionField(name: "command", value: "make test")], edited: true)
        XCTAssertEqual(PermissionCardView.shown(text: "make", state: one), "make test")
        XCTAssertEqual(PermissionCardView.answerLabel(one.answer, edited: true), "Allowed once, as edited")
        XCTAssertEqual(PermissionCardView.answerLabel(one.answer, edited: false), "Allowed once")

        let two = PermissionState(open: false, fields: [PermissionField(name: "channel", value: "C1"),
                                                        PermissionField(name: "text", value: "hello there")], edited: true)
        XCTAssertEqual(PermissionCardView.shown(text: "post", state: two), "channel: C1\ntext: hello there")
    }

    func testAnOlderMacsCardHasNoFieldsToReword() throws {
        let line = #"{"id":"m1","kind":"permission","text":"make","permission":{"request":"r","open":true,"tool":"Bash","always":[]}}"#
        guard case .permission(let text, let state) = try XCTUnwrap(TranscriptRow.rows(from: [try message(line)]).first).kind else {
            return XCTFail("a permission row")
        }
        XCTAssertNil(state.fields)
        XCTAssertEqual(PermissionCardView.shown(text: text, state: state), "make")
    }

    func testACardEndsARunOfToolLinesAsOtherCardsDo() throws {
        let tool = try message(#"{"id":"t1","kind":"tool","text":"Bash — make"}"#)
        let card = try message(#"{"id":"m1","kind":"permission","text":"make","permission":{"request":"r","open":true,"tool":"Bash","always":[]}}"#)
        let after = try message(#"{"id":"t2","kind":"tool","text":"Read — a.swift"}"#)

        let rows = TranscriptRow.rows(from: [tool, card, after])

        XCTAssertEqual(rows.map(\.id), ["t1", "m1", "t2"])
    }

    // MARK: - Choices

    private let one = ChoiceQuestionInfo(question: "Tea or coffee?", header: "Drink", multiSelect: false,
                                         options: [.init(label: "Tea", description: ""), .init(label: "Coffee", description: "")])
    private let several = ChoiceQuestionInfo(question: "Which sizes?", header: "Size", multiSelect: true,
                                             options: [.init(label: "S"), .init(label: "M"), .init(label: "L")])

    func testAChoicesMessageBecomesACardWithItsQuestions() throws {
        let line = #"{"id":"c1","kind":"choices","text":"Tea or coffee?","choices":{"request":"req-q","open":true,"questions":[{"question":"Tea or coffee?","header":"Drink","multiSelect":false,"options":[{"label":"Tea","description":"Leaves"}]}]}}"#

        guard case .choices(let state) = try XCTUnwrap(TranscriptRow.rows(from: [try message(line)]).first).kind else {
            return XCTFail("a choices row")
        }
        XCTAssertEqual(state.request, "req-q")
        XCTAssertEqual(state.questions?.first?.options?.first, ChoiceOptionInfo(label: "Tea", description: "Leaves"))
        XCTAssertNil(state.answers)
    }

    func testAQuestionThatTakesOneAnswerHoldsOnlyTheNewestPick() {
        XCTAssertEqual(ChoicesCardView.toggling("Coffee", in: ["Tea"], of: one), ["Coffee"])
    }

    func testAQuestionThatTakesSeveralAddsAndRemovesInTheOrderListed() {
        XCTAssertEqual(ChoicesCardView.toggling("S", in: ["L"], of: several), ["S", "L"])
        XCTAssertEqual(ChoicesCardView.toggling("L", in: ["S", "L"], of: several), ["S"])
    }

    func testAnswersAreWhatWasTypedElseThePicksAndNothingUntilEveryQuestionHasOne() {
        XCTAssertNil(ChoicesCardView.answers(to: [one, several], picked: [0: ["Tea"]], typed: [:]))
        XCTAssertEqual(ChoicesCardView.answers(to: [one, several], picked: [0: ["Tea"], 1: ["S", "L"]], typed: [:]), ["Tea", "S, L"])
        XCTAssertEqual(ChoicesCardView.answers(to: [one], picked: [0: ["Tea"]], typed: [0: " Water "]), ["Water"])
        XCTAssertNil(ChoicesCardView.answers(to: [one], picked: [:], typed: [0: "  "]))
    }

    // MARK: - Mode and tasks

    func testModesReadByTheirPickerNamesAndAnUnknownOneAsItself() {
        XCTAssertEqual(PermissionMode.name("default"), "Ask")
        XCTAssertEqual(PermissionMode.name("dontAsk"), "Don't Ask")
        XCTAssertEqual(PermissionMode.name("acceptEdits"), "Accept Edits")
        XCTAssertEqual(PermissionMode.name("something-new"), "something-new")
        XCTAssertEqual(PermissionMode.all.map(\.id), ["auto", "acceptEdits", "plan", "default", "dontAsk", "bypassPermissions"])
    }

    func testTheAgentListCarriesTheModeAndAnOlderMacsListDoesNot() throws {
        let reply = try JSONDecoder().decode(AgentsReply.self, from: Data(
            #"{"agents":[{"id":"a","name":"Builder","state":"idle","mode":"acceptEdits"},{"id":"b","name":"Old"}]}"#.utf8))
        XCTAssertEqual(reply.agents?.map(\.mode), ["acceptEdits", nil])
    }

    func testARunningTaskReadsByWhatItWasStartedWith() throws {
        let reply = try JSONDecoder().decode(AgentTasksReply.self, from: Data(
            #"{"agent":"a","tasks":[{"id":"t1","kind":"subagent","description":"Run the tests","subagent":"general-purpose"},{"id":"t2","kind":"shell","description":" "}]}"#.utf8))
        let tasks = try XCTUnwrap(reply.tasks)
        XCTAssertEqual(tasks.map(\.title), ["Run the tests", "shell"])
        XCTAssertEqual(tasks.first?.subagent, "general-purpose")
    }
}
