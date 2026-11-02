import XCTest
import KiteloopCore
@testable import Kiteloop

/// The cards under "Memory index: <agent>" belong to that agent.
///
/// The Memory page listed every pending proposal in the project under whichever
/// agent's index happened to be open, so Approve on a card wrote a fact into a
/// different agent's memory — the card named its own agent in caption text and
/// the heading above it named someone else. `proposalsForSelectedAgent` is what
/// the page iterates now; `pendingProposals` stays whole, because the sidebar's
/// Pending section and the Memory row's badge count the project on purpose.
@MainActor
final class MemoryViewModelSelectedAgentProposalsTests: XCTestCase {
    private var tempDir: URL!
    private var project: KiteloopProject!

    override func setUpWithError() throws {
        tempDir = try makeTemporaryDirectory(prefix: "memory-selected-agent-proposals")
        project = KiteloopProject(rootURL: tempDir)
        try project.ensureDirectoryExists()
    }

    func testOnlyTheSelectedAgentsProposalsAreOffered() async throws {
        let manager = MemoryManager(project: project)
        let coders = try await manager.proposeUpdate(agentID: "coder", content: "The deploy script lives in scripts/ship.sh")
        let reviewers = try await manager.proposeUpdate(agentID: "reviewer", content: "Releases go out on a Thursday")
        let viewModel = MemoryViewModel(memoryManager: manager)
        viewModel.selectedAgentID = "coder"
        await viewModel.refresh()

        XCTAssertEqual(viewModel.proposalsForSelectedAgent.map(\.id), [coders.id],
                       "approving under coder's index must not write into reviewer's memory")
        XCTAssertEqual(Set(viewModel.pendingProposals.map(\.id)), [coders.id, reviewers.id],
                       "the sidebar's Pending count and the Memory badge stay project-wide")
    }

    func testNothingIsOfferedWithNoAgentSelected() async throws {
        let manager = MemoryManager(project: project)
        _ = try await manager.proposeUpdate(agentID: "coder", content: "The deploy script lives in scripts/ship.sh")
        let viewModel = MemoryViewModel(memoryManager: manager)
        await viewModel.refresh()

        XCTAssertNil(viewModel.selectedAgentID)
        XCTAssertTrue(viewModel.proposalsForSelectedAgent.isEmpty,
                      "the page has no index to write into until an agent is picked")
        XCTAssertEqual(viewModel.pendingProposals.count, 1)
    }

    /// The heading and the divider are drawn only when this list is non-empty,
    /// so an agent nobody has proposed anything for shows neither.
    func testAnAgentWithNoProposalsOffersNone() async throws {
        let manager = MemoryManager(project: project)
        _ = try await manager.proposeUpdate(agentID: "coder", content: "The deploy script lives in scripts/ship.sh")
        let viewModel = MemoryViewModel(memoryManager: manager)
        viewModel.selectedAgentID = "scribe"
        await viewModel.refresh()

        XCTAssertTrue(viewModel.proposalsForSelectedAgent.isEmpty)
        XCTAssertEqual(viewModel.pendingProposals.count, 1)
    }

    /// The sidebar's Pending section names each agent once. Three facts from
    /// one agent used to draw three rows reading the same name and carrying the
    /// same selection tag, so the list looked like three agents.
    func testSeveralProposalsFromOneAgentCollapseToOneRow() async throws {
        let manager = MemoryManager(project: project)
        _ = try await manager.proposeUpdate(agentID: "coder", content: "The deploy script lives in scripts/ship.sh")
        _ = try await manager.proposeUpdate(agentID: "coder", content: "Releases go out on a Thursday")
        let viewModel = MemoryViewModel(memoryManager: manager)
        await viewModel.refresh()

        XCTAssertEqual(viewModel.pendingAgents, [.init(agentID: "coder", count: 2)],
                       "one row per agent, with how many of its facts are waiting")
        XCTAssertEqual(viewModel.pendingProposals.count, 2,
                       "the header's count and the Memory badge stay project-wide")
    }

    /// Two agents are two rows, in agent-id order so a refresh does not
    /// reshuffle them.
    func testEachPendingAgentGetsOneRowInAStableOrder() async throws {
        let manager = MemoryManager(project: project)
        _ = try await manager.proposeUpdate(agentID: "reviewer", content: "Releases go out on a Thursday")
        _ = try await manager.proposeUpdate(agentID: "coder", content: "The deploy script lives in scripts/ship.sh")
        let viewModel = MemoryViewModel(memoryManager: manager)
        await viewModel.refresh()

        let expected: [MemoryViewModel.PendingAgent] = [
            .init(agentID: "coder", count: 1),
            .init(agentID: "reviewer", count: 1),
        ]
        XCTAssertEqual(viewModel.pendingAgents, expected)

        await viewModel.refresh()
        XCTAssertEqual(viewModel.pendingAgents, expected, "the order holds across refreshes")
    }
}
