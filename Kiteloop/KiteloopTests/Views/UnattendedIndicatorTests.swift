import XCTest
@testable import Kiteloop

/// Coverage for the "running unattended" indicator's derivation — the rule that
/// decides whether an agent gets a badge at all, and whether it reads as actively
/// running or standing by under autopilot.
final class UnattendedIndicatorTests: XCTestCase {

    // MARK: - No indicator for attended agents

    /// A human-driven agent gets no indicator, working or not — the badge must mean
    /// "nobody is gating this", not "this agent is busy".
    func testAttendedAgentHasNoIndicator() {
        for state: Agent.AgentState in [.idle, .working, .waitingForHuman, .crashed] {
            XCTAssertNil(
                UnattendedIndicator.model(agentName: "Builder", isUnattended: false, state: state),
                "Attended agent in state \(state) should have no unattended indicator"
            )
        }
    }

    // MARK: - Active vs standing by

    /// Mid-turn under autopilot: the indicator is active and uses the filled bolt.
    func testWorkingUnattendedAgentIsActive() throws {
        let model = try XCTUnwrap(
            UnattendedIndicator.model(agentName: "Builder", isUnattended: true, state: .working)
        )

        XCTAssertTrue(model.isActive)
        XCTAssertEqual(model.label, "Unattended")
        XCTAssertEqual(model.symbol, "bolt.fill")
        XCTAssertTrue(model.help.contains("Builder"), "Help text should name the agent: \(model.help)")
        XCTAssertTrue(model.help.contains("auto mode"), "Help text should say who decides tool calls: \(model.help)")
    }

    /// Autopilot marks worker *and* reviewer for the whole item, so an idle one is
    /// still unattended — shown, but distinguishable from the one actually running.
    func testIdleUnattendedAgentIsStandingBy() throws {
        let model = try XCTUnwrap(
            UnattendedIndicator.model(agentName: "Reviewer", isUnattended: true, state: .idle)
        )

        XCTAssertFalse(model.isActive)
        XCTAssertEqual(model.label, "Unattended · standing by")
        XCTAssertEqual(model.symbol, "bolt")
        XCTAssertTrue(model.help.contains("Reviewer"), "Help text should name the agent: \(model.help)")
    }

    /// A stalled or crashed unattended agent keeps the indicator: the run is still
    /// under autopilot, and that's exactly when a human wants to notice.
    func testNonWorkingStatesStillShowIndicator() throws {
        for state: Agent.AgentState in [.waitingForHuman, .crashed] {
            let model = try XCTUnwrap(
                UnattendedIndicator.model(agentName: "Builder", isUnattended: true, state: state),
                "State \(state) should still show the unattended indicator"
            )
            XCTAssertFalse(model.isActive, "State \(state) is not an active turn")
        }
    }

    /// The two variants are distinct models, so a view diffing on them redraws when
    /// the agent starts or finishes a turn.
    func testActiveAndStandingByModelsDiffer() throws {
        let active = try XCTUnwrap(
            UnattendedIndicator.model(agentName: "Builder", isUnattended: true, state: .working)
        )
        let standingBy = try XCTUnwrap(
            UnattendedIndicator.model(agentName: "Builder", isUnattended: true, state: .idle)
        )

        XCTAssertNotEqual(active, standingBy)
    }
}
