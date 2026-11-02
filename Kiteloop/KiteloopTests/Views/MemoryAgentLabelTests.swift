import KiteloopCore
import XCTest
@testable import Kiteloop

/// The Memory tab's Pending rows, index heading and proposal cards name an agent
/// the way its Agents section does — by the name it was given, not its id.
final class MemoryAgentLabelTests: XCTestCase {

    private let agents = [
        Agent(id: "a1", name: "Builder", model: "sonnet", systemPrompt: "", tools: [], denied: [], permissionMode: "auto", state: .idle),
        Agent(id: "a2", name: "Reviewer", model: "sonnet", systemPrompt: "", tools: [], denied: [], permissionMode: "auto", state: .idle),
    ]

    func testAnAgentOnTheTeamIsNamedByItsName() {
        XCTAssertEqual(MemoryBrowserView.agentLabel(for: "a2", in: agents), "Reviewer")
    }

    /// A proposal filed for an agent since removed still says whose it was.
    func testAnIdNoAgentHasIsShownUnchanged() {
        XCTAssertEqual(MemoryBrowserView.agentLabel(for: "gone-agent", in: agents), "gone-agent")
    }
}
