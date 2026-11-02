import XCTest
@testable import Kiteloop

/// Coverage for the "waiting on you" badge's derivation — the rule that
/// decides whether an agent's sidebar avatar gets the loud orange badge for an
/// `ask_human` question nobody has answered yet. That the state is actually
/// reached is `ChatViewModelAskHumanTests`' to show.
final class AgentStateBadgeTests: XCTestCase {

    // MARK: - Only .waitingForHuman shows the badge

    /// An attended agent shows the badge only while its question is open.
    func testOnlyWaitingForHumanShowsBadge() {
        for state: Agent.AgentState in [.idle, .working, .crashed] {
            XCTAssertNil(
                AgentAvatarView.waitingBadge(agentName: "Builder", isUnattended: false, state: state),
                "State \(state) should have no waiting badge"
            )
        }

        XCTAssertNotNil(
            AgentAvatarView.waitingBadge(agentName: "Builder", isUnattended: false, state: .waitingForHuman)
        )
    }

    // MARK: - Unattended agents wear the other badge

    /// An unattended agent's corner is the unattended indicator's, which stays
    /// up whatever the state; its question reaches the human through the notice
    /// and the menu bar instead.
    func testUnattendedAgentNeverShowsBadge() {
        for state: Agent.AgentState in [.idle, .working, .waitingForHuman, .crashed] {
            XCTAssertNil(
                AgentAvatarView.waitingBadge(agentName: "Builder", isUnattended: true, state: state),
                "Unattended agent in state \(state) should have no waiting badge"
            )
        }
    }

    // MARK: - Content

    /// The badge names the agent, says what it is waiting for — an answer to
    /// its question, not a permission prompt, which no longer exists — and
    /// uses a hand-raised symbol, distinct from the unattended indicator's bolt.
    func testWaitingBadgeContent() throws {
        let badge = try XCTUnwrap(
            AgentAvatarView.waitingBadge(agentName: "Reviewer", isUnattended: false, state: .waitingForHuman)
        )

        XCTAssertEqual(badge.symbol, "hand.raised.fill")
        XCTAssertEqual(badge.help, "Reviewer is waiting on you — answer its question in the chat to continue.")
    }
}
