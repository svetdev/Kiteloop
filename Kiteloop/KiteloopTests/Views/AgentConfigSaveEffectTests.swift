import XCTest
@testable import Kiteloop

/// Coverage for what saving the Configure… sheet does to the agent's live
/// session — the CLI reads `--mcp-config` only when it is spawned, so a key
/// saved while the agent runs reaches it only through a restart.
final class AgentConfigSaveEffectTests: XCTestCase {

    private struct WriteRefused: Error {}

    private func effect(hasSession: Bool, state: Agent.AgentState?) -> AgentEditorSheet.SaveEffect? {
        try? AgentConfigSheet.saveEffect(hasSession: hasSession, state: state, write: {}).get()
    }

    /// An idle agent with a live session is restarted, so the saved key takes.
    func testIdleSessionIsRestarted() {
        XCTAssertEqual(effect(hasSession: true, state: .idle), .restartSession)
    }

    /// No session: nothing to restart, the sheet just closes.
    func testNoSessionJustDismisses() {
        XCTAssertEqual(effect(hasSession: false, state: .idle), .dismiss)
        XCTAssertEqual(effect(hasSession: false, state: nil), .dismiss)
    }

    /// A turn in flight is left alone and the sheet says when the change takes.
    func testWorkingAgentIsLeftAlone() {
        XCTAssertEqual(effect(hasSession: true, state: .working), .applyAtNextStart)
    }

    /// The sheet decides by Edit Agent…'s rule, not a copy of it.
    func testFollowsTheEditorsRule() {
        for hasSession in [true, false] {
            for state: Agent.AgentState? in [nil, .idle, .working, .crashed] {
                XCTAssertEqual(
                    effect(hasSession: hasSession, state: state),
                    AgentEditorSheet.saveEffect(hasSession: hasSession, state: state)
                )
            }
        }
    }

    /// A write that throws decides nothing, so nothing is restarted.
    func testFailedWriteDecidesNothing() {
        let result = AgentConfigSheet.saveEffect(hasSession: true, state: .idle, write: { throw WriteRefused() })
        guard case .failure(let error) = result else {
            return XCTFail("A refused write should fail, got \(result)")
        }
        XCTAssertTrue(error is WriteRefused)
    }
}
