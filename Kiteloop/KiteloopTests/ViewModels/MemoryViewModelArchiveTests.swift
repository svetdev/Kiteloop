import XCTest
import KiteloopCore
@testable import Kiteloop

/// The Memory tab's own control for a full index: archiving a fact through the
/// view model has to behave like `approve`/`reject` already do — a failure
/// lands in `lastWriteError` rather than being swallowed, and a success
/// refreshes the list and the topic count without the caller switching tabs.
@MainActor
final class MemoryViewModelArchiveTests: XCTestCase {
    private var tempDir: URL!
    private var project: KiteloopProject!

    override func setUpWithError() throws {
        tempDir = try makeTemporaryDirectory(prefix: "memory-archive")
        project = KiteloopProject(rootURL: tempDir)
        try project.ensureDirectoryExists()
    }

    func testArchivingARealFactUpdatesTheListAndTopicCount() async throws {
        let manager = MemoryManager(project: project)
        let p = try await manager.proposeUpdate(agentID: "coder", content: "A fact worth remembering")
        try await manager.approve(proposalID: p.id)

        let viewModel = MemoryViewModel(memoryManager: manager)
        viewModel.selectedAgentID = "coder"
        await viewModel.refresh()
        XCTAssertEqual(viewModel.memoryFacts.count, 1)
        XCTAssertEqual(viewModel.memoryTopics.count, 1)
        let topic = viewModel.memoryFacts[0].topic

        await viewModel.archive(topic: topic)

        XCTAssertNil(viewModel.lastWriteError)
        XCTAssertTrue(viewModel.memoryFacts.isEmpty)
        XCTAssertTrue(viewModel.memoryTopics.isEmpty)
    }

    func testArchivingASupersededFactsLeftoverBodyLeavesTheIndexAlone() async throws {
        let manager = MemoryManager(project: project)
        let old = try await manager.proposeUpdate(agentID: "coder", content: "Staging deploys go through the old bastion host named zanzibar")
        try await manager.approve(proposalID: old.id)
        let leftover = "staging-deploys-go-through-the-old-bastion-host"
        let replacement = try await manager.proposeUpdate(
            agentID: "coder",
            content: "Staging deploys go through the new gateway\nsupersedes: \(leftover)"
        )
        try await manager.approve(proposalID: replacement.id)

        let viewModel = MemoryViewModel(memoryManager: manager)
        viewModel.selectedAgentID = "coder"
        await viewModel.refresh()
        XCTAssertFalse(viewModel.memoryFacts.contains { $0.topic == leftover }, "the superseded line has left the index")
        XCTAssertTrue(viewModel.memoryTopics.contains { $0.id == leftover }, "its body is still among the topics")
        let recalledBefore = await manager.recallMemory(agentID: "coder", query: "zanzibar")
        XCTAssertTrue(recalledBefore.contains("zanzibar"))
        let indexBefore = viewModel.currentMemory

        await viewModel.archive(topic: leftover)

        XCTAssertNil(viewModel.lastWriteError)
        XCTAssertFalse(viewModel.memoryTopics.contains { $0.id == leftover })
        XCTAssertEqual(viewModel.archivedTopics.map(\.id), [leftover])
        XCTAssertEqual(viewModel.currentMemory, indexBefore, "archiving a body with no line must not rewrite the index")
        let recalledAfter = await manager.recallMemory(agentID: "coder", query: "zanzibar")
        XCTAssertEqual(recalledAfter, "")
    }

    func testArchivingAnUnknownTopicReportsTheFailure() async throws {
        let manager = MemoryManager(project: project)
        let p = try await manager.proposeUpdate(agentID: "coder", content: "A fact worth remembering")
        try await manager.approve(proposalID: p.id)

        let viewModel = MemoryViewModel(memoryManager: manager)
        viewModel.selectedAgentID = "coder"
        await viewModel.refresh()

        await viewModel.archive(topic: "not-a-real-topic")

        XCTAssertNotNil(viewModel.lastWriteError, "an unknown topic must not read as archived")
        XCTAssertEqual(viewModel.memoryFacts.count, 1, "nothing was actually archived")
    }

    func testRestoringAnArchivedFactRefreshesTheArchivedAndLiveLists() async throws {
        let manager = MemoryManager(project: project)
        let p = try await manager.proposeUpdate(agentID: "coder", content: "A fact worth remembering")
        try await manager.approve(proposalID: p.id)

        let viewModel = MemoryViewModel(memoryManager: manager)
        viewModel.selectedAgentID = "coder"
        await viewModel.refresh()
        let topic = viewModel.memoryFacts[0].topic
        await viewModel.archive(topic: topic)
        XCTAssertEqual(viewModel.archivedTopics.map(\.id), [topic])

        await viewModel.restore(topic: topic)

        XCTAssertNil(viewModel.lastWriteError)
        XCTAssertTrue(viewModel.archivedTopics.isEmpty)
        XCTAssertEqual(viewModel.memoryTopics.map(\.id), [topic])
        XCTAssertEqual(viewModel.memoryFacts.map(\.topic), [topic])
    }

    func testARefusedRestoreReportsTheFailure() async throws {
        let manager = MemoryManager(project: project)
        let p = try await manager.proposeUpdate(agentID: "coder", content: "Sessions are spawned through the runtime")
        try await manager.approve(proposalID: p.id)

        let viewModel = MemoryViewModel(memoryManager: manager)
        viewModel.selectedAgentID = "coder"
        await viewModel.refresh()
        let topic = viewModel.memoryFacts[0].topic
        await viewModel.archive(topic: topic)
        let again = try await manager.proposeUpdate(agentID: "coder", content: "Sessions are spawned through the runtime today")
        try await manager.approve(proposalID: again.id)

        await viewModel.restore(topic: topic)

        XCTAssertTrue(viewModel.lastWriteError?.contains("already covered") ?? false, "\(String(describing: viewModel.lastWriteError))")
        XCTAssertEqual(viewModel.archivedTopics.map(\.id), [topic], "nothing was actually restored")
    }

    func testDeletingAnArchivedFactClearsTheErrorAndDropsItFromTheArchive() async throws {
        let manager = MemoryManager(project: project)
        let p = try await manager.proposeUpdate(agentID: "coder", content: "A fact worth remembering")
        try await manager.approve(proposalID: p.id)

        let viewModel = MemoryViewModel(memoryManager: manager)
        viewModel.selectedAgentID = "coder"
        await viewModel.refresh()
        let topic = viewModel.memoryFacts[0].topic
        await viewModel.archive(topic: topic)
        await viewModel.archive(topic: "not-a-real-topic")
        XCTAssertNotNil(viewModel.lastWriteError)
        XCTAssertEqual(viewModel.archivedTopics.map(\.id), [topic])

        await viewModel.deleteArchived(topic: topic)

        XCTAssertNil(viewModel.lastWriteError)
        XCTAssertTrue(viewModel.archivedTopics.isEmpty)
    }

    func testARefusedArchivedDeleteReportsTheFailure() async throws {
        let manager = MemoryManager(project: project)
        let p = try await manager.proposeUpdate(agentID: "coder", content: "A fact worth remembering")
        try await manager.approve(proposalID: p.id)

        let viewModel = MemoryViewModel(memoryManager: manager)
        viewModel.selectedAgentID = "coder"
        await viewModel.refresh()
        let topic = viewModel.memoryFacts[0].topic
        await viewModel.archive(topic: topic)
        await viewModel.deleteArchived(topic: topic)

        await viewModel.deleteArchived(topic: topic)

        XCTAssertTrue(viewModel.lastWriteError?.contains(topic) ?? false, "\(String(describing: viewModel.lastWriteError))")
        XCTAssertTrue(viewModel.archivedTopics.isEmpty)
    }

    func testARewriteThatLandsClearsTheErrorAndRefreshesTheFacts() async throws {
        let manager = MemoryManager(project: project)
        let p = try await manager.proposeUpdate(agentID: "coder", content: "The dev server port is 8080")
        try await manager.approve(proposalID: p.id)

        let viewModel = MemoryViewModel(memoryManager: manager)
        viewModel.selectedAgentID = "coder"
        await viewModel.refresh()
        let topic = viewModel.memoryFacts[0].topic
        await viewModel.archive(topic: "not-a-real-topic")
        XCTAssertNotNil(viewModel.lastWriteError)

        let landed = await viewModel.rewrite(topic: topic, content: "The dev server port is 8443")

        XCTAssertTrue(landed)
        XCTAssertNil(viewModel.lastWriteError)
        XCTAssertEqual(viewModel.memoryFacts.map(\.topic), [topic])
        XCTAssertEqual(viewModel.memoryFacts.map(\.headline), ["The dev server port is 8443"])
    }

    func testARefusedRewriteReportsTheFailure() async throws {
        let manager = MemoryManager(project: project)
        let p = try await manager.proposeUpdate(agentID: "coder", content: "The dev server port is 8080")
        try await manager.approve(proposalID: p.id)

        let viewModel = MemoryViewModel(memoryManager: manager)
        viewModel.selectedAgentID = "coder"
        await viewModel.refresh()
        let topic = viewModel.memoryFacts[0].topic

        let landed = await viewModel.rewrite(topic: topic, content: "   ")

        XCTAssertFalse(landed)
        XCTAssertNotNil(viewModel.lastWriteError, "blank text must not read as a correction that landed")
        XCTAssertEqual(viewModel.memoryFacts.map(\.headline), ["The dev server port is 8080"])
    }

    func testAnAddThatLandsClearsTheErrorAndShowsTheNewFact() async throws {
        let manager = MemoryManager(project: project)
        let viewModel = MemoryViewModel(memoryManager: manager)
        viewModel.selectedAgentID = "coder"
        await viewModel.refresh()
        await viewModel.archive(topic: "not-a-real-topic")
        XCTAssertNotNil(viewModel.lastWriteError)

        let landed = await viewModel.add(content: "Deploys go through staging first")

        XCTAssertTrue(landed)
        XCTAssertNil(viewModel.lastWriteError)
        XCTAssertEqual(viewModel.memoryFacts.map(\.headline), ["Deploys go through staging first"])
        XCTAssertEqual(viewModel.memoryTopics.map(\.id), viewModel.memoryFacts.map(\.topic))
    }

    func testARefusedAddReportsTheFailure() async throws {
        let manager = MemoryManager(project: project)
        let viewModel = MemoryViewModel(memoryManager: manager)
        viewModel.selectedAgentID = "coder"
        await viewModel.refresh()

        let landed = await viewModel.add(content: "   ")

        XCTAssertFalse(landed)
        XCTAssertNotNil(viewModel.lastWriteError, "blank text must not read as a fact that landed")
        XCTAssertTrue(viewModel.memoryFacts.isEmpty)
    }
}
