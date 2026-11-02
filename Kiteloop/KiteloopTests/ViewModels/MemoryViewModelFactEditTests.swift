import XCTest
import KiteloopCore
@testable import Kiteloop

/// An open fact correction belongs to the agent it was opened under.
///
/// A topic is a slug of the fact's text, so two agents that learned the same
/// thing share one. The editor used to be keyed by topic alone: moving the
/// selection carried it to the other agent's row, and Save rewrote that
/// agent's fact with text meant for the first.
@MainActor
final class MemoryViewModelFactEditTests: XCTestCase {
    private var tempDir: URL!
    private var project: KiteloopProject!

    override func setUpWithError() throws {
        tempDir = try makeTemporaryDirectory(prefix: "memory-fact-edit")
        project = KiteloopProject(rootURL: tempDir)
        try project.ensureDirectoryExists()
    }

    /// Both agents hold "The build runs on Xcode" under one topic; returns it.
    private func makeSharedFact(_ manager: MemoryManager) async throws -> String {
        for agentID in ["scout", "coder"] {
            let p = try await manager.proposeUpdate(agentID: agentID, content: "The build runs on Xcode")
            try await manager.approve(proposalID: p.id)
        }
        let scoutTopics = await manager.memoryTopics(agentID: "scout").map(\.id)
        let coderTopics = await manager.memoryTopics(agentID: "coder").map(\.id)
        XCTAssertEqual(scoutTopics.count, 1)
        XCTAssertEqual(scoutTopics, coderTopics, "the premise: both agents share the topic")
        return try XCTUnwrap(scoutTopics.first)
    }

    private func body(_ manager: MemoryManager, agentID: String, topic: String) async -> String? {
        await manager.memoryTopics(agentID: agentID).first { $0.id == topic }?.body
    }

    func testSavingAfterMovingToAnotherAgentWritesTheAgentTheEditWasOpenedUnder() async throws {
        let manager = MemoryManager(project: project)
        let topic = try await makeSharedFact(manager)
        let viewModel = MemoryViewModel(memoryManager: manager)
        viewModel.selectedAgentID = "scout"
        await viewModel.refresh()
        let coderBefore = await body(manager, agentID: "coder", topic: topic)

        viewModel.openFactEdit(topic: topic, text: "The build runs on Xcode")
        viewModel.updateFactEdit(text: "The build runs on Xcode 17")
        viewModel.selectedAgentID = "coder"
        await viewModel.refresh()
        await viewModel.saveFactEdit()

        XCTAssertNil(viewModel.lastWriteError)
        let scoutBody = await body(manager, agentID: "scout", topic: topic)
        let scoutAfter = try XCTUnwrap(scoutBody)
        XCTAssertTrue(scoutAfter.contains("The build runs on Xcode 17"), "the correction lands in scout's fact")
        let coderAfter = await body(manager, agentID: "coder", topic: topic)
        XCTAssertEqual(coderAfter, coderBefore, "coder's fact is untouched")
        XCTAssertNil(viewModel.factEdit, "a save that landed closes the edit")
    }

    func testTheEditIsShownOnlyOnItsOwnAgentsPageAndKeepsItsText() async throws {
        let manager = MemoryManager(project: project)
        let topic = try await makeSharedFact(manager)
        let viewModel = MemoryViewModel(memoryManager: manager)
        viewModel.selectedAgentID = "scout"

        viewModel.openFactEdit(topic: topic, text: "The build runs on Xcode")
        viewModel.updateFactEdit(text: "The build runs on Xcode 17")
        XCTAssertEqual(viewModel.factEditForSelectedAgent?.topic, topic)

        viewModel.selectedAgentID = "coder"
        XCTAssertNil(viewModel.factEditForSelectedAgent, "coder's page shows no editor")

        viewModel.selectedAgentID = "scout"
        XCTAssertEqual(viewModel.factEditForSelectedAgent?.topic, topic)
        XCTAssertEqual(viewModel.factEditForSelectedAgent?.text, "The build runs on Xcode 17")
    }

    func testARefusedSaveKeepsTheEditOpenWithItsText() async throws {
        let manager = MemoryManager(project: project)
        let topic = try await makeSharedFact(manager)
        let viewModel = MemoryViewModel(memoryManager: manager)
        viewModel.selectedAgentID = "scout"
        await viewModel.refresh()

        viewModel.openFactEdit(topic: topic, text: "The build runs on Xcode")
        viewModel.updateFactEdit(text: "   ")
        await viewModel.saveFactEdit()

        XCTAssertNotNil(viewModel.lastWriteError, "blank text must not read as a correction that landed")
        XCTAssertEqual(viewModel.factEditForSelectedAgent?.text, "   ")
        XCTAssertEqual(viewModel.factEditForSelectedAgent?.topic, topic)
    }

    func testCancelClosesTheEdit() async throws {
        let manager = MemoryManager(project: project)
        let topic = try await makeSharedFact(manager)
        let viewModel = MemoryViewModel(memoryManager: manager)
        viewModel.selectedAgentID = "scout"

        viewModel.openFactEdit(topic: topic, text: "The build runs on Xcode")
        viewModel.cancelFactEdit()

        XCTAssertNil(viewModel.factEdit)
    }
}
