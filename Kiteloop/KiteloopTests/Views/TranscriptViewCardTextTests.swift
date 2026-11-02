import KiteloopCore
import XCTest
@testable import Kiteloop

/// Transcript mode prints a plan card and an agent's question as text, so a
/// conversation read or copied there keeps the plan and what was asked.
/// Permission requests stay out of it.
final class TranscriptViewCardTextTests: XCTestCase {

    private func agentMessage(_ content: Message.Content) -> Message {
        Message(id: UUID(), timestamp: .now, sender: .agent("Planner"), content: content)
    }

    func testAnUnansweredPlanPrintsItsText() {
        let plan = agentMessage(.plan(Message.PlanProposal(text: "# Plan\n\n1. Add the helper")))

        let text = TranscriptView.cardText(for: plan)

        XCTAssertEqual(text, "# Plan\n\n1. Add the helper")
    }

    func testAnAnsweredPlanAlsoPrintsWhatWasChosen() {
        let plan = agentMessage(.plan(Message.PlanProposal(text: "1. Add the helper", answer: .approveAuto)))

        let text = TranscriptView.cardText(for: plan)

        XCTAssertTrue(text?.contains("1. Add the helper") == true, "the plan's text is missing: \(text ?? "nil")")
        XCTAssertTrue(text?.contains("Approved — building in Auto") == true,
                      "the choice is missing: \(text ?? "nil")")
        XCTAssertTrue(text?.contains(PlanCard.answeredLabel(.approveAuto)) == true)
    }

    func testAnAgentsQuestionPrintsTheQuestion() {
        let question = agentMessage(.approval(Message.ApprovalRequest(
            id: "q1", action: "Which branch should I base this on?", tool: "ask_human"
        )))

        XCTAssertEqual(TranscriptView.cardText(for: question), "Which branch should I base this on?")
    }

    func testAPermissionRequestPrintsNothing() {
        let request = agentMessage(.approval(Message.ApprovalRequest(
            id: "p1", action: "Run rm -rf build", tool: "Bash"
        )))

        XCTAssertNil(TranscriptView.cardText(for: request))
    }
}
