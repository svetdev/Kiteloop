import XCTest
import KiteloopCore
@testable import Kiteloop

/// Rejecting a proposal has to say whether the rejection landed.
///
/// `MemoryManager` writes the proposal's JSON before it marks the record
/// rejected, so a status write onto a directory the write cannot reach leaves the
/// proposal pending — and the card stays in the list. Silence there reads exactly
/// like a rejection that worked and a list that has not refreshed, so it has to
/// leave the error the Memory tab already renders.
@MainActor
final class MemoryViewModelRejectionTests: XCTestCase {
    private var tempDir: URL!
    private var project: KiteloopProject!

    override func setUpWithError() throws {
        tempDir = try makeTemporaryDirectory(prefix: "memory-rejection")
        project = KiteloopProject(rootURL: tempDir)
        try project.ensureDirectoryExists()
    }

    /// Makes the agent's `proposals` directory unwritable for the duration of the
    /// test — `AtomicFileWriter.write(_:to:)` cannot create its temporary file
    /// there, so the status write fails with the filed proposal untouched.
    private func sealProposalsDirectory(agentID: String) throws {
        let fm = FileManager.default
        let path = project.agentDir(for: agentID).appending(path: "proposals").path(percentEncoded: false)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: path)
        addTeardownBlock {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        }
    }

    private func unsealProposalsDirectory(agentID: String) throws {
        let path = project.agentDir(for: agentID).appending(path: "proposals").path(percentEncoded: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }

    func testFailedRejectionReportsTheErrorAndLeavesTheProposalPending() async throws {
        let manager = MemoryManager(project: project)
        let proposal = try await manager.proposeUpdate(agentID: "scout", content: "A fact nobody wants.")
        let viewModel = MemoryViewModel(memoryManager: manager)
        await viewModel.refresh()
        try sealProposalsDirectory(agentID: "scout")

        await viewModel.reject(proposal)

        XCTAssertNotNil(viewModel.lastWriteError, "a rejection that did not land has to say so")
        let pending = await manager.pendingProposals()
        XCTAssertEqual(pending.map(\.id), [proposal.id])
        XCTAssertEqual(viewModel.pendingProposals.map(\.id), [proposal.id])
    }

    func testSuccessfulRejectionClearsTheErrorAndDropsTheProposal() async throws {
        let manager = MemoryManager(project: project)
        let proposal = try await manager.proposeUpdate(agentID: "scout", content: "A fact nobody wants.")
        let viewModel = MemoryViewModel(memoryManager: manager)
        await viewModel.refresh()

        // Fail first, so the clearing is a change and not the initial state.
        try sealProposalsDirectory(agentID: "scout")
        await viewModel.reject(proposal)
        XCTAssertNotNil(viewModel.lastWriteError)

        try unsealProposalsDirectory(agentID: "scout")
        await viewModel.reject(proposal)

        XCTAssertNil(viewModel.lastWriteError)
        let pending = await manager.pendingProposals()
        XCTAssertTrue(pending.isEmpty)
        XCTAssertTrue(viewModel.pendingProposals.isEmpty)
    }
}
