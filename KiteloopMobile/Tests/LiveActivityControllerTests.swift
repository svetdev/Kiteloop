import XCTest
@testable import KiteloopMobile

/// How the chat's stream moves a turn's Live Activity on: the agent's newest
/// line, a question or plan it stops on, and the end of the turn.
final class LiveActivityControllerTests: XCTestCase {
    private let working = AgentActivityAttributes.ContentState(working: true, status: "Working", line: "")

    private func message(_ kind: String, _ text: String, sender: String = "b1") -> AgentEvent {
        AgentEvent(type: "message", agent: "b1", working: nil,
                   message: TranscriptMessage(id: "m", sender: sender, kind: kind, text: text, at: nil))
    }

    func testTheAgentsNewestLineBecomesTheActivitysLine() {
        let next = LiveActivityController.state(after: message("text", "Found it"), current: working)
        XCTAssertEqual(next, .init(working: true, status: "Working", line: "Found it"))
    }

    func testYourOwnMessageChangesNothing() {
        XCTAssertNil(LiveActivityController.state(after: message("text", "go", sender: "you"), current: working))
    }

    func testAQuestionSaysTheTurnWaitsOnYou() {
        let next = LiveActivityController.state(after: message("question", "Keep it?"), current: working)
        XCTAssertEqual(next?.status, "Waiting for your answer")
        XCTAssertEqual(next?.working, false)
    }

    func testTheTurnEndingSaysDone() {
        let next = LiveActivityController.state(
            after: AgentEvent(type: "state", agent: "b1", working: false, message: nil), current: working)
        XCTAssertEqual(next?.status, "Done")
    }

    func testAStateItAlreadyHasChangesNothing() {
        XCTAssertNil(LiveActivityController.state(
            after: AgentEvent(type: "state", agent: "b1", working: true, message: nil), current: working))
    }
}
