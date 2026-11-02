import XCTest
import KiteloopCore
@testable import Kiteloop

/// Saving an edited proposal has to say whether the edit landed.
///
/// The card closes its editor only on a save that worked; a refused one — blank
/// text, a full index, a sealed proposals folder — keeps the human's rewrite in
/// the editor, so the view model has to report which it was.
@MainActor
final class MemoryViewModelEditTests: XCTestCase {
    private var tempDir: URL!
    private var project: KiteloopProject!

    override func setUpWithError() throws {
        tempDir = try makeTemporaryDirectory(prefix: "memory-edit")
        project = KiteloopProject(rootURL: tempDir)
        try project.ensureDirectoryExists()
    }

    func testRefusedEditReportsFailureAndLeavesTheProposalPending() async throws {
        let manager = MemoryManager(project: project)
        let proposal = try await manager.proposeUpdate(agentID: "scout", content: "The build runs on Xcode.")
        let viewModel = MemoryViewModel(memoryManager: manager)
        await viewModel.refresh()

        let landed = await viewModel.edit(proposal, newContent: "   \n")

        XCTAssertFalse(landed, "a blank fact can never be recorded")
        XCTAssertNotNil(viewModel.lastWriteError, "an edit that did not land has to say so")
        let pending = await manager.pendingProposals()
        XCTAssertEqual(pending.map(\.id), [proposal.id])
        XCTAssertEqual(viewModel.pendingProposals.map(\.id), [proposal.id])
    }

    func testEditThatLandsReportsSuccessClearsTheErrorAndDropsTheProposal() async throws {
        let manager = MemoryManager(project: project)
        let proposal = try await manager.proposeUpdate(agentID: "scout", content: "The build runs on Xcode.")
        let viewModel = MemoryViewModel(memoryManager: manager)
        await viewModel.refresh()

        // Fail first, so the clearing is a change and not the initial state.
        let refused = await viewModel.edit(proposal, newContent: "")
        XCTAssertFalse(refused)
        XCTAssertNotNil(viewModel.lastWriteError)

        let landed = await viewModel.edit(proposal, newContent: "The build runs on Xcode 17.")

        XCTAssertTrue(landed)
        XCTAssertNil(viewModel.lastWriteError)
        let pending = await manager.pendingProposals()
        XCTAssertTrue(pending.isEmpty)
        XCTAssertTrue(viewModel.pendingProposals.isEmpty)
    }
}
