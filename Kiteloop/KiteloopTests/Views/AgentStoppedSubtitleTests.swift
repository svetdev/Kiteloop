import KiteloopCore
import XCTest
@testable import Kiteloop

/// A stopped agent's sidebar row says so — "Stopped · " ahead of the model —
/// so it no longer passes for a running agent that happens to be idle.
final class AgentStoppedSubtitleTests: XCTestCase {

    private func agent(model: String, asideOf: String? = nil) -> Agent {
        Agent(
            id: "a1",
            name: "Builder",
            model: model,
            systemPrompt: "",
            tools: [],
            denied: [],
            permissionMode: "auto",
            asideOfAgentID: asideOf,
            state: .idle
        )
    }

    func testStoppedAgentLeadsWithStoppedAndStillNamesTheModel() {
        XCTAssertEqual(
            KiteloopSidebar.agentSubtitle(for: agent(model: "us.anthropic.claude-opus-4-8"), isStopped: true),
            "Stopped · Opus"
        )
    }

    func testRunningAgentReadsAsItsModelAlone() {
        let running = agent(model: "us.anthropic.claude-opus-4-8")
        XCTAssertEqual(KiteloopSidebar.agentSubtitle(for: running, isStopped: false), "Opus")
        XCTAssertEqual(
            KiteloopSidebar.agentSubtitle(for: running, isStopped: false),
            KiteloopSidebar.modelSubtitle(for: running)
        )
    }

    /// The prefix goes ahead of the existing line, aside marker included.
    func testStoppedAsideKeepsItsAsidePrefix() {
        XCTAssertEqual(
            KiteloopSidebar.agentSubtitle(for: agent(model: "mystery-model-v9", asideOf: "a0"), isStopped: true),
            "Stopped · aside · mystery-model-v9"
        )
    }
}
