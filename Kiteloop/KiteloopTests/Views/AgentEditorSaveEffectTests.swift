import XCTest
@testable import Kiteloop

/// Coverage for what saving the Edit Agent sheet does to the agent's live
/// session — everything the sheet writes but the name is read when the CLI
/// process is spawned, so a running session keeps its old model, tools and
/// prompt until it is restarted.
final class AgentEditorSaveEffectTests: XCTestCase {

    /// A session that is not mid-turn is restarted, so the next turn spawns
    /// with the edited values.
    func testIdleSessionIsRestarted() {
        XCTAssertEqual(
            AgentEditorSheet.saveEffect(hasSession: true, state: .idle),
            .restartSession
        )
    }

    /// No session behind the agent: nothing to restart, so the sheet just
    /// closes and the values are picked up at its first start.
    func testNoSessionJustDismisses() {
        for state: Agent.AgentState? in [nil, .idle, .working, .crashed] {
            XCTAssertEqual(
                AgentEditorSheet.saveEffect(hasSession: false, state: state),
                .dismiss,
                "State \(String(describing: state)) with no session should only dismiss"
            )
        }
    }

    /// A turn in flight is never stopped underneath the agent; the sheet says
    /// so instead of closing as though the change had taken.
    func testWorkingAgentIsLeftAlone() {
        XCTAssertEqual(
            AgentEditorSheet.saveEffect(hasSession: true, state: .working),
            .applyAtNextStart
        )
    }

    private func agent(id: String, name: String) -> Agent {
        Agent(id: id, name: name, model: "sonnet", systemPrompt: "", tools: [], denied: [],
              permissionMode: "default", state: .idle)
    }

    private var team: [Agent] {
        [agent(id: "a", name: "Builder"), agent(id: "b", name: "Reviewer")]
    }

    /// A blank or all-spaces name would leave an empty sidebar row.
    func testBlankNameIsRefused() {
        XCTAssertNotNil(AgentEditorSheet.nameRefusal("", agentID: "a", agents: team))
        XCTAssertNotNil(AgentEditorSheet.nameRefusal("   ", agentID: "a", agents: team))
    }

    /// A teammate's name in any case would make one of the two unreachable
    /// by name.
    func testTeammatesNameInAnyCaseIsRefused() {
        XCTAssertNotNil(AgentEditorSheet.nameRefusal("reviewer", agentID: "a", agents: team))
        XCTAssertNotNil(AgentEditorSheet.nameRefusal("  REVIEWER ", agentID: "a", agents: team))
    }

    /// The agent's own name stays allowed, so a save that changes only the
    /// model goes through, and so does a name nobody else carries.
    func testOwnNameAndUnusedNameAreAllowed() {
        XCTAssertNil(AgentEditorSheet.nameRefusal("Builder", agentID: "a", agents: team))
        XCTAssertNil(AgentEditorSheet.nameRefusal("Planner", agentID: "a", agents: team))
    }

    /// New Agent passes an id no agent carries, since the agent has none yet.
    func testNewAgentRefusesBlankName() {
        XCTAssertNotNil(AgentEditorSheet.nameRefusal("", agentID: "", agents: team))
        XCTAssertNotNil(AgentEditorSheet.nameRefusal("   ", agentID: "", agents: team))
    }

    func testNewAgentRefusesTeammatesNameInAnyCase() {
        XCTAssertNotNil(AgentEditorSheet.nameRefusal("reviewer", agentID: "", agents: team))
        XCTAssertNotNil(AgentEditorSheet.nameRefusal("  REVIEWER ", agentID: "", agents: team))
    }

    func testNewAgentAllowsUnusedName() {
        XCTAssertNil(AgentEditorSheet.nameRefusal("Planner", agentID: "", agents: team))
    }
}
