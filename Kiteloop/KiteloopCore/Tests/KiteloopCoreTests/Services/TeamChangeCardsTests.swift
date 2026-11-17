import XCTest
@testable import KiteloopCore

/// The cards an agent's hire and fire calls wait on: marked with what became
/// of them, abandoned once when read back still waiting, and logged with the
/// project they are in.
final class TeamChangeCardsTests: XCTestCase {

    private func card(_ id: String, tool: String = "hire_agent",
                      status: Message.ApprovalRequest.ApprovalStatus = .pending) -> Message {
        Message(id: UUID(), timestamp: Date(timeIntervalSince1970: 0), sender: .agent("lead"),
                content: .approval(Message.ApprovalRequest(id: id, action: "Hire 'Cody' (coder)", tool: tool,
                                                           status: status, before: "Lead", after: "Lead, Cody")))
    }

    private func statuses(_ messages: [Message]) -> [String: Message.ApprovalRequest.ApprovalStatus] {
        var found: [String: Message.ApprovalRequest.ApprovalStatus] = [:]
        for message in messages {
            if case .approval(let request) = message.content { found[request.id] = request.status }
        }
        return found
    }

    func testOnlyHireAndFireCardsAreTeamChanges() {
        let asks = Message.ApprovalRequest(id: "q", action: "Which one?", tool: "ask_human")

        XCTAssertFalse(TeamChangeCards.isTeamChange(asks))
        for tool in ["hire_agent", "fire_agent"] {
            XCTAssertTrue(TeamChangeCards.isTeamChange(Message.ApprovalRequest(id: "c", action: "", tool: tool)))
        }
    }

    func testMarkingSetsTheOneCardsStatus() {
        var messages = [card("a"), card("b")]

        let marked = TeamChangeCards.mark("b", .approved, in: &messages)

        XCTAssertEqual(marked?.status, .approved)
        XCTAssertEqual(statuses(messages), ["a": .pending, "b": .approved])
        XCTAssertNil(TeamChangeCards.mark("gone", .denied, in: &messages), "a chat that was cleared holds no card")
    }

    /// A chat read back from disk: every team card still waiting is
    /// abandoned, decided ones and other approvals are left alone.
    func testPendingTeamCardsAreAbandonedAndReturned() {
        var messages = [card("old", status: .denied), card("hire"), card("fire", tool: "fire_agent"),
                        card("question", tool: "ask_human")]

        let abandoned = TeamChangeCards.abandonPending(in: &messages)

        XCTAssertEqual(abandoned.map(\.id), ["hire", "fire"])
        XCTAssertEqual(statuses(messages), ["old": .denied, "hire": .abandoned, "fire": .abandoned, "question": .pending])
    }

    /// The mark is what makes it once: a second read finds nothing to log.
    func testAnAbandonedCardIsNotAbandonedAgain() throws {
        var messages = [card("hire")]
        _ = TeamChangeCards.abandonPending(in: &messages)
        let reloaded = try JSONDecoder().decode([Message].self, from: JSONEncoder().encode(messages))
        var again = reloaded

        XCTAssertEqual(TeamChangeCards.abandonPending(in: &again).map(\.id), [])
        XCTAssertEqual(statuses(again), ["hire": .abandoned])
    }

    func testTheLogLineNamesTheAgentTheToolTheTeamsAndTheProject() {
        let at = Date(timeIntervalSince1970: 1_756_684_800)

        let record = TeamChangeCards.record(tool: "fire_agent", before: "Lead, Bob", after: "Lead", requestedBy: "Lead",
                                            project: "/work/site", decision: .abandoned, at: at)

        XCTAssertEqual(record, ConfigChangeLog.Record(requestedBy: "Lead", kind: "team", tool: "fire_agent",
                                                      before: "Lead, Bob", after: "Lead", decision: .abandoned,
                                                      at: at, project: "/work/site"))
    }
}
