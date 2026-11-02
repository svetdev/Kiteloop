import XCTest
import KiteloopCore
@testable import Kiteloop

/// The sidebar's Memory badge reads `pendingProposals.count`, and until the
/// window's tick re-asked for it that count only ever moved when somebody
/// opened the Memory tab — the one moment the badge has nothing left to tell
/// them. `refreshPendingProposals()` is what the tick calls: it re-reads the
/// proposal list and touches nothing else the tab loads, so the number can
/// ride a two-second cadence without re-reading memory files nobody is
/// browsing.
@MainActor
final class MemoryViewModelPendingCountTests: XCTestCase {
    private var tempDir: URL!
    private var project: KiteloopProject!

    override func setUpWithError() throws {
        tempDir = try makeTemporaryDirectory(prefix: "memory-pending-count")
        project = KiteloopProject(rootURL: tempDir)
        try project.ensureDirectoryExists()
    }

    func testAProposalFiledAfterTheLastReadIsCountedWithoutOpeningTheTab() async throws {
        let manager = MemoryManager(project: project)
        let viewModel = MemoryViewModel(memoryManager: manager)
        await viewModel.refreshPendingProposals()
        XCTAssertTrue(viewModel.pendingProposals.isEmpty)

        _ = try await manager.proposeUpdate(agentID: "coder", content: "A fact worth remembering")

        await viewModel.refreshPendingProposals()

        XCTAssertEqual(viewModel.pendingProposals.count, 1,
                       "the badge has to move with no agent selected and no refresh()")
        XCTAssertNil(viewModel.selectedAgentID)
    }

    func testRefreshingTheCountLeavesEverythingElseTheTabLoaded() async throws {
        let manager = MemoryManager(project: project)
        for content in ["The deploy script lives in scripts/ship.sh", "Releases go out on a Thursday"] {
            let proposal = try await manager.proposeUpdate(agentID: "coder", content: content)
            try await manager.approve(proposalID: proposal.id)
        }
        try await manager.saveSharedContext("what the project is")
        try await manager.saveFleetKnowledge("what the runs learned")

        let viewModel = MemoryViewModel(memoryManager: manager)
        viewModel.selectedAgentID = "coder"
        await viewModel.refresh()
        // One fact archived, one left in the index, so every list this asserts
        // on is non-empty — an unchanged empty array proves nothing.
        try await manager.archiveFact(agentID: "coder", topic: viewModel.memoryFacts[0].topic)
        await viewModel.refresh()

        let currentMemory = viewModel.currentMemory
        let facts = viewModel.memoryFacts
        let topics = viewModel.memoryTopics
        let archived = viewModel.archivedTopics
        let sharedContext = viewModel.sharedContext
        let fleetKnowledge = viewModel.fleetKnowledge
        XCTAssertFalse(currentMemory.isEmpty)
        XCTAssertFalse(facts.isEmpty)
        XCTAssertFalse(topics.isEmpty)
        XCTAssertFalse(archived.isEmpty, "the archived list has to be non-empty for this to prove anything")
        XCTAssertFalse(sharedContext.isEmpty)
        XCTAssertFalse(fleetKnowledge.isEmpty)

        _ = try await manager.proposeUpdate(agentID: "coder", content: "A fact nobody has approved yet")
        await viewModel.refreshPendingProposals()

        XCTAssertEqual(viewModel.pendingProposals.count, 1)
        XCTAssertEqual(viewModel.currentMemory, currentMemory)
        XCTAssertEqual(viewModel.memoryFacts.map(\.topic), facts.map(\.topic))
        XCTAssertEqual(viewModel.memoryTopics.map(\.id), topics.map(\.id))
        XCTAssertEqual(viewModel.archivedTopics.map(\.id), archived.map(\.id))
        XCTAssertEqual(viewModel.sharedContext, sharedContext)
        XCTAssertEqual(viewModel.fleetKnowledge, fleetKnowledge)
    }

    func testAProposalResolvedElsewhereDropsOutAtTheNextRead() async throws {
        let manager = MemoryManager(project: project)
        let approved = try await manager.proposeUpdate(agentID: "coder", content: "A fact worth remembering")
        let rejected = try await manager.proposeUpdate(agentID: "coder", content: "A fact worth forgetting")

        let viewModel = MemoryViewModel(memoryManager: manager)
        await viewModel.refreshPendingProposals()
        XCTAssertEqual(viewModel.pendingProposals.count, 2)

        try await manager.approve(proposalID: approved.id)
        await viewModel.refreshPendingProposals()
        XCTAssertEqual(viewModel.pendingProposals.map(\.id), [rejected.id],
                       "an approval elsewhere has to bring the badge down")

        try await manager.reject(proposalID: rejected.id)
        await viewModel.refreshPendingProposals()
        XCTAssertTrue(viewModel.pendingProposals.isEmpty, "the badge falls as well as rises")
    }
}
