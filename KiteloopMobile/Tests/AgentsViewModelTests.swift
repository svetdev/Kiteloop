import XCTest
@testable import KiteloopMobile

/// How the chat applies `GET /v1/agents/events`: a reply still streaming
/// replaces itself by id instead of piling up rows, a new message appends, and
/// a reconnect asks only for what came after the last message held.
@MainActor
final class AgentsViewModelTests: XCTestCase {
    private func message(_ id: String, _ text: String, sender: String = "Builder") -> TranscriptMessage {
        TranscriptMessage(id: id, sender: sender, kind: "text", text: text, at: nil)
    }

    func testAStreamedDeltaUpdatesTheMessageInPlace() {
        let transcript = [message("a", "hi", sender: "you"), message("b", "Found")]
        let event = AgentEvent(type: "message", agent: "x", working: nil, message: message("b", "Found it"))

        let updated = AgentsViewModel.applying(event, to: transcript)

        XCTAssertEqual(updated.count, 2, "no second row for the same message")
        XCTAssertEqual(updated.last?.text, "Found it")
    }

    func testANewMessageIsAppended() {
        let updated = AgentsViewModel.applying(
            AgentEvent(type: "message", agent: "x", working: nil, message: message("c", "next")),
            to: [message("a", "hi")])

        XCTAssertEqual(updated.map(\.id), ["a", "c"])
    }

    func testAStateEventLeavesTheTranscriptAlone() {
        let transcript = [message("a", "hi")]

        let updated = AgentsViewModel.applying(AgentEvent(type: "state", agent: "x", working: true, message: nil), to: transcript)

        XCTAssertEqual(updated.map(\.id), ["a"])
    }

    func testTheTranscriptKeepsOnlyTheNewestWindow() {
        let full = (0..<AgentsViewModel.window).map { message("m\($0)", "t") }

        let updated = AgentsViewModel.applying(
            AgentEvent(type: "message", agent: "x", working: nil, message: message("new", "t")), to: full)

        XCTAssertEqual(updated.count, AgentsViewModel.window)
        XCTAssertEqual(updated.last?.id, "new")
    }

    func testAReconnectAsksForWhatCameAfterTheLastMessageHeld() {
        let client = ControlClient(baseURL: "http://100.1.1.1:4517", token: "t")

        let path = AgentsViewModel.streamPath(client, project: "alpha", agent: "b1", after: "last-id")
        let fresh = AgentsViewModel.streamPath(client, project: "alpha", agent: "b1", after: nil)

        XCTAssertTrue(path.hasPrefix("/v1/agents/events?"))
        XCTAssertTrue(path.contains("after=last-id"))
        XCTAssertFalse(fresh.contains("after="), "an empty chat starts from now")
    }

    func testAMessageFrameDecodes() throws {
        let line = #"{"type":"message","agent":"b1","message":{"id":"m1","sender":"Builder","kind":"text","text":"ok","at":"2026-10-26T00:00:00Z"}}"#

        let event = try XCTUnwrap(AgentEvent.decode(line))

        XCTAssertEqual(event.message?.id, "m1")
        XCTAssertEqual(event.message?.text, "ok")
    }

    func testTheStreamsWorkingStateWinsOverTheAgentList() {
        XCTAssertTrue(ChatView.showsWorking(state: "idle", streamed: true, refreshFailure: nil))
        XCTAssertFalse(ChatView.showsWorking(state: "working", streamed: false, refreshFailure: nil))
        XCTAssertFalse(ChatView.showsWorking(state: "working", streamed: true, refreshFailure: "timed out"))
    }

    // MARK: - Plans and questions

    func testAnOpenPlanBecomesAPlanCardRow() throws {
        let line = #"{"id":"p1","sender":"Planner","kind":"plan","text":"1. Do it","at":"x","plan":{"open":true}}"#
        let message = try JSONDecoder().decode(TranscriptMessage.self, from: Data(line.utf8))

        let row = try XCTUnwrap(TranscriptRow.rows(from: [message]).first)

        guard case .plan(let id, let text, let answer) = row.kind else { return XCTFail("a plan row") }
        XCTAssertEqual(id, "p1")
        XCTAssertEqual(text, "1. Do it")
        XCTAssertNil(answer, "an open plan offers its three choices")
    }

    func testAnAnsweredPlanCarriesItsAnswer() throws {
        let line = #"{"id":"p1","sender":"Planner","kind":"plan","text":"x","plan":{"open":false,"answer":"approveAuto"}}"#
        let message = try JSONDecoder().decode(TranscriptMessage.self, from: Data(line.utf8))

        guard case .plan(_, _, let answer) = try XCTUnwrap(TranscriptRow.rows(from: [message]).first).kind else {
            return XCTFail("a plan row")
        }
        XCTAssertEqual(answer, "approveAuto")
        XCTAssertEqual(TranscriptRow.planAnswerLabel("approveAuto"), "Approved · building in Auto")
        XCTAssertEqual(TranscriptRow.planAnswerLabel("keepPlanning"), "Kept planning")
    }

    func testAQuestionRowCarriesTheRequestItAnswers() throws {
        let line = #"{"id":"q1","sender":"Builder","kind":"question","text":"Keep the old rounding?","question":{"request":"tool-7","open":true}}"#
        let message = try JSONDecoder().decode(TranscriptMessage.self, from: Data(line.utf8))

        guard case .question(let request, let text, let open) = try XCTUnwrap(TranscriptRow.rows(from: [message]).first).kind else {
            return XCTFail("a question row")
        }
        XCTAssertEqual(request, "tool-7")
        XCTAssertEqual(text, "Keep the old rounding?")
        XCTAssertTrue(open)
    }

    // MARK: - Hiring

    func testAHireAnswerBecomesAnIdleAgentInTheList() throws {
        let agent = try XCTUnwrap(AgentsViewModel.hiredAgent(["agentId": "a9", "name": "Reviewer", "model": "sonnet"]))

        XCTAssertEqual(agent.id, "a9")
        XCTAssertEqual(agent.name, "Reviewer")
        XCTAssertEqual(agent.state, "idle")
        XCTAssertNil(AgentsViewModel.hiredAgent(["error": "Project not open"]))
    }

    // MARK: - Quick replies

    func testAQuickReplyIsSentWhileTheAgentIsIdleAndNothingIsTyped() {
        XCTAssertEqual(AgentsViewModel.quickReplyAction("Continue", draft: "", working: false), .send)
    }

    func testWhileTheAgentWorksAQuickReplyFillsTheDraftToQueue() {
        XCTAssertEqual(AgentsViewModel.quickReplyAction("Run the tests", draft: " ", working: true), .draft("Run the tests"))
    }

    func testAQuickReplyAddsToTextAlreadyTypedRatherThanSendingOverIt() {
        XCTAssertEqual(AgentsViewModel.quickReplyAction("Run the tests", draft: "Fix the refund bug.", working: false),
                       .draft("Fix the refund bug. Run the tests"))
    }

    func testTheMacsListDecodes() throws {
        let reply = try JSONDecoder().decode(QuickRepliesReply.self, from: Data(#"{"replies":["Continue","Ship it"]}"#.utf8))
        XCTAssertEqual(reply.replies, ["Continue", "Ship it"])
    }
}
