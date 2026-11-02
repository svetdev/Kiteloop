import XCTest
import KiteloopCore
@testable import Kiteloop

/// Saving the project context has to say whether it landed.
///
/// `.kiteloop/context.md` rides into every agent's system prompt, and the editor
/// holding the edit is the only other copy of it — so a save onto a directory the
/// write cannot reach must leave the error visible and the typed text still the
/// view model's business, not report the rejected text back as the project's
/// context.
@MainActor
final class MemoryViewModelSharedContextTests: XCTestCase {
    private var tempDir: URL!
    private var project: KiteloopProject!

    override func setUpWithError() throws {
        tempDir = try makeTemporaryDirectory(prefix: "memory-shared-context")
        project = KiteloopProject(rootURL: tempDir)
        try project.ensureDirectoryExists()
    }

    /// Makes `.kiteloop` unwritable for the duration of the test — an atomic
    /// write cannot create its temporary file there, so the save fails with the
    /// file already on disk untouched.
    private func sealKiteloopDirectory() throws {
        let fm = FileManager.default
        let path = project.kiteloopDirURL.path(percentEncoded: false)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: path)
        addTeardownBlock {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        }
    }

    func testFailedSaveReportsTheErrorAndKeepsWhatIsOnDisk() async throws {
        try "The context we already had.".write(to: project.contextURL, atomically: true, encoding: .utf8)
        let viewModel = MemoryViewModel(memoryManager: MemoryManager(project: project))
        await viewModel.refresh()
        try sealKiteloopDirectory()

        await viewModel.saveSharedContext("The edit that cannot land.")

        XCTAssertNotNil(viewModel.lastWriteError, "a save that did not land has to say so")
        XCTAssertEqual(viewModel.sharedContext, "The context we already had.")
    }

    func testSuccessfulSaveClearsTheErrorAndShowsTheNewText() async throws {
        try "The context we already had.".write(to: project.contextURL, atomically: true, encoding: .utf8)
        let viewModel = MemoryViewModel(memoryManager: MemoryManager(project: project))
        await viewModel.refresh()

        // Fail first, so the clearing is a change and not the initial state.
        try sealKiteloopDirectory()
        await viewModel.saveSharedContext("The edit that cannot land.")
        XCTAssertNotNil(viewModel.lastWriteError)

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: project.kiteloopDirURL.path(percentEncoded: false)
        )
        await viewModel.saveSharedContext("The edit that lands.")

        XCTAssertNil(viewModel.lastWriteError)
        XCTAssertEqual(viewModel.sharedContext, "The edit that lands.")
        let onDisk = try String(contentsOf: project.contextURL, encoding: .utf8)
        XCTAssertEqual(onDisk, "The edit that lands.")
    }

    /// A view model whose last save failed, still sitting on the selection the
    /// failure happened under.
    private func viewModelWithAFailedSave(selecting selection: String?) async throws -> MemoryViewModel {
        let viewModel = MemoryViewModel(memoryManager: MemoryManager(project: project))
        viewModel.selectedAgentID = selection
        await viewModel.refresh()
        try sealKiteloopDirectory()
        await viewModel.saveSharedContext("The edit that cannot land.")
        XCTAssertNotNil(viewModel.lastWriteError)
        return viewModel
    }

    func testTheErrorStandsWhileTheSelectionIsUnchanged() async throws {
        let viewModel = try await viewModelWithAFailedSave(selecting: MemoryBrowserView.projectContextID)

        // What the shared editors read to decide the edit is still unsaved:
        // re-selecting the same row is not a move.
        viewModel.selectedAgentID = MemoryBrowserView.projectContextID
        await viewModel.refresh()

        XCTAssertNotNil(viewModel.lastWriteError, "the failure belongs to the page it happened on")
    }

    func testSelectingAnotherAgentClearsTheError() async throws {
        let viewModel = try await viewModelWithAFailedSave(selecting: "coder")

        viewModel.selectedAgentID = "scribe"

        XCTAssertNil(viewModel.lastWriteError, "one agent's failed write is not the next agent's")
    }

    func testSelectingTheSharedRowsClearsTheError() async throws {
        let toProjectContext = try await viewModelWithAFailedSave(selecting: "coder")
        toProjectContext.selectedAgentID = MemoryBrowserView.projectContextID
        XCTAssertNil(toProjectContext.lastWriteError)

        let toFleetKnowledge = try await viewModelWithAFailedSave(selecting: "coder")
        toFleetKnowledge.selectedAgentID = MemoryBrowserView.fleetKnowledgeID
        XCTAssertNil(toFleetKnowledge.lastWriteError)
    }

    // MARK: - Drafts outlive the editor

    func testAProjectContextDraftSurvivesTheSelectionMovingAway() async throws {
        try "The context we already had.".write(to: project.contextURL, atomically: true, encoding: .utf8)
        let viewModel = MemoryViewModel(memoryManager: MemoryManager(project: project))
        viewModel.selectedAgentID = MemoryBrowserView.projectContextID
        await viewModel.refresh()

        viewModel.sharedContextDraft = "An edit not yet saved."
        viewModel.selectedAgentID = "coder"
        await viewModel.refresh()
        viewModel.selectedAgentID = MemoryBrowserView.projectContextID
        await viewModel.refresh()

        XCTAssertEqual(viewModel.sharedContextDraft, "An edit not yet saved.")
        XCTAssertTrue(viewModel.hasUnsavedSharedContext)
    }

    func testASuccessfulSaveClearsTheProjectContextDraft() async throws {
        let viewModel = MemoryViewModel(memoryManager: MemoryManager(project: project))
        await viewModel.refresh()

        viewModel.sharedContextDraft = "The edit that lands."
        await viewModel.saveSharedContext("The edit that lands.")

        XCTAssertNil(viewModel.sharedContextDraft)
        XCTAssertFalse(viewModel.hasUnsavedSharedContext)
        XCTAssertEqual(viewModel.sharedContext, "The edit that lands.")
    }

    func testAFailedSaveKeepsTheProjectContextDraftAcrossASelectionMove() async throws {
        let viewModel = MemoryViewModel(memoryManager: MemoryManager(project: project))
        viewModel.selectedAgentID = MemoryBrowserView.projectContextID
        await viewModel.refresh()
        try sealKiteloopDirectory()

        viewModel.sharedContextDraft = "The edit that cannot land."
        await viewModel.saveSharedContext("The edit that cannot land.")
        XCTAssertNotNil(viewModel.lastWriteError)
        viewModel.selectedAgentID = "coder"
        viewModel.selectedAgentID = MemoryBrowserView.projectContextID
        await viewModel.refresh()

        XCTAssertEqual(viewModel.sharedContextDraft, "The edit that cannot land.")
        XCTAssertTrue(viewModel.hasUnsavedSharedContext)
    }

    func testRefreshLeavesTheDraftsAlone() async throws {
        let viewModel = MemoryViewModel(memoryManager: MemoryManager(project: project))
        await viewModel.refresh()
        viewModel.sharedContextDraft = "Context edit."
        viewModel.fleetKnowledgeDraft = "Knowledge edit."
        try "Changed on disk underneath.".write(to: project.contextURL, atomically: true, encoding: .utf8)

        await viewModel.refresh()

        XCTAssertEqual(viewModel.sharedContextDraft, "Context edit.")
        XCTAssertEqual(viewModel.fleetKnowledgeDraft, "Knowledge edit.")
    }

    func testAFleetKnowledgeDraftSurvivesTheSelectionMovingAway() async throws {
        let viewModel = MemoryViewModel(memoryManager: MemoryManager(project: project))
        viewModel.selectedAgentID = MemoryBrowserView.fleetKnowledgeID
        await viewModel.refresh()

        viewModel.fleetKnowledgeDraft = "A learned line not yet saved."
        viewModel.selectedAgentID = "coder"
        await viewModel.refresh()
        viewModel.selectedAgentID = MemoryBrowserView.fleetKnowledgeID
        await viewModel.refresh()

        XCTAssertEqual(viewModel.fleetKnowledgeDraft, "A learned line not yet saved.")
        XCTAssertTrue(viewModel.hasUnsavedFleetKnowledge)
    }

    func testASuccessfulSaveClearsTheFleetKnowledgeDraft() async throws {
        let viewModel = MemoryViewModel(memoryManager: MemoryManager(project: project))
        await viewModel.refresh()

        viewModel.fleetKnowledgeDraft = "A learned line that lands."
        await viewModel.saveFleetKnowledge("A learned line that lands.")

        XCTAssertNil(viewModel.lastWriteError)
        XCTAssertNil(viewModel.fleetKnowledgeDraft)
        XCTAssertEqual(viewModel.fleetKnowledge, "A learned line that lands.")
    }

    func testAFailedSaveKeepsTheFleetKnowledgeDraftAcrossASelectionMove() async throws {
        let viewModel = MemoryViewModel(memoryManager: MemoryManager(project: project))
        viewModel.selectedAgentID = MemoryBrowserView.fleetKnowledgeID
        await viewModel.refresh()
        try sealKiteloopDirectory()

        viewModel.fleetKnowledgeDraft = "A learned line that cannot land."
        await viewModel.saveFleetKnowledge("A learned line that cannot land.")
        XCTAssertNotNil(viewModel.lastWriteError)
        viewModel.selectedAgentID = "coder"
        viewModel.selectedAgentID = MemoryBrowserView.fleetKnowledgeID
        await viewModel.refresh()

        XCTAssertEqual(viewModel.fleetKnowledgeDraft, "A learned line that cannot land.")
        XCTAssertTrue(viewModel.hasUnsavedFleetKnowledge)
    }

    // MARK: - Revert drops a draft

    private var fleetKnowledgeURL: URL {
        project.kiteloopDirURL.appending(path: CoordinatorKnowledge.fileName)
    }

    func testRevertingAProjectContextDraftShowsTheFileAsItIsOnDisk() async throws {
        try "The context we already had.".write(to: project.contextURL, atomically: true, encoding: .utf8)
        let viewModel = MemoryViewModel(memoryManager: MemoryManager(project: project))
        await viewModel.refresh()
        viewModel.sharedContextDraft = "A half-made change."

        viewModel.revertSharedContext()

        XCTAssertNil(viewModel.sharedContextDraft)
        XCTAssertFalse(viewModel.hasUnsavedSharedContext)
        XCTAssertEqual(viewModel.sharedContext, "The context we already had.")
        XCTAssertEqual(try String(contentsOf: project.contextURL, encoding: .utf8), "The context we already had.")
    }

    func testRevertingAFleetKnowledgeDraftLeavesTheFileUntouched() async throws {
        try "A line the fleet learned.".write(to: fleetKnowledgeURL, atomically: true, encoding: .utf8)
        let viewModel = MemoryViewModel(memoryManager: MemoryManager(project: project))
        await viewModel.refresh()
        viewModel.fleetKnowledgeDraft = "A half-made change."

        viewModel.revertFleetKnowledge()

        XCTAssertNil(viewModel.fleetKnowledgeDraft)
        XCTAssertFalse(viewModel.hasUnsavedFleetKnowledge)
        XCTAssertEqual(viewModel.fleetKnowledge, "A line the fleet learned.")
        XCTAssertEqual(try String(contentsOf: fleetKnowledgeURL, encoding: .utf8), "A line the fleet learned.")
    }

    func testRevertingAfterAFailedSaveClearsTheError() async throws {
        let viewModel = MemoryViewModel(memoryManager: MemoryManager(project: project))
        await viewModel.refresh()
        try sealKiteloopDirectory()
        viewModel.sharedContextDraft = "The edit that cannot land."
        await viewModel.saveSharedContext("The edit that cannot land.")
        XCTAssertNotNil(viewModel.lastWriteError)

        viewModel.revertSharedContext()

        XCTAssertNil(viewModel.lastWriteError)
    }

    func testRevertingAFailedFleetKnowledgeSaveClearsTheError() async throws {
        let viewModel = MemoryViewModel(memoryManager: MemoryManager(project: project))
        await viewModel.refresh()
        try sealKiteloopDirectory()
        viewModel.fleetKnowledgeDraft = "A learned line that cannot land."
        await viewModel.saveFleetKnowledge("A learned line that cannot land.")
        XCTAssertNotNil(viewModel.lastWriteError)

        viewModel.revertFleetKnowledge()

        XCTAssertNil(viewModel.lastWriteError)
    }

    func testRevertingOneDraftLeavesTheOtherAlone() async throws {
        let viewModel = MemoryViewModel(memoryManager: MemoryManager(project: project))
        await viewModel.refresh()
        viewModel.sharedContextDraft = "Context edit."
        viewModel.fleetKnowledgeDraft = "Knowledge edit."

        viewModel.revertSharedContext()
        XCTAssertEqual(viewModel.fleetKnowledgeDraft, "Knowledge edit.")

        viewModel.sharedContextDraft = "Context edit."
        viewModel.revertFleetKnowledge()
        XCTAssertEqual(viewModel.sharedContextDraft, "Context edit.")
    }

    // MARK: - A save does not write over the file moving on

    func testAFleetKnowledgeSaveRefusesWhenTheFileChangedSinceTheDraftBegan() async throws {
        try "Text A.".write(to: fleetKnowledgeURL, atomically: true, encoding: .utf8)
        let viewModel = MemoryViewModel(memoryManager: MemoryManager(project: project))
        await viewModel.refresh()
        viewModel.fleetKnowledgeDraft = "My edit."
        try "Text B, with what a run learned.".write(to: fleetKnowledgeURL, atomically: true, encoding: .utf8)

        await viewModel.saveFleetKnowledge("My edit.")

        XCTAssertEqual(viewModel.lastWriteError, MemoryViewModel.changedOnDiskMessage)
        XCTAssertTrue(viewModel.lastWriteError?.contains("changed on disk") ?? false)
        XCTAssertEqual(try String(contentsOf: fleetKnowledgeURL, encoding: .utf8), "Text B, with what a run learned.")
        XCTAssertEqual(viewModel.fleetKnowledgeDraft, "My edit.")
        XCTAssertEqual(viewModel.fleetKnowledge, "Text B, with what a run learned.")

        await viewModel.saveFleetKnowledge("My edit.")

        XCTAssertNil(viewModel.lastWriteError)
        XCTAssertNil(viewModel.fleetKnowledgeDraft)
        XCTAssertEqual(try String(contentsOf: fleetKnowledgeURL, encoding: .utf8), "My edit.")
    }

    func testAProjectContextSaveRefusesWhenTheFileChangedSinceTheDraftBegan() async throws {
        try "Text A.".write(to: project.contextURL, atomically: true, encoding: .utf8)
        let viewModel = MemoryViewModel(memoryManager: MemoryManager(project: project))
        await viewModel.refresh()
        viewModel.sharedContextDraft = "My edit."
        try "Text B.".write(to: project.contextURL, atomically: true, encoding: .utf8)

        await viewModel.saveSharedContext("My edit.")

        XCTAssertEqual(viewModel.lastWriteError, MemoryViewModel.changedOnDiskMessage)
        XCTAssertEqual(try String(contentsOf: project.contextURL, encoding: .utf8), "Text B.")
        XCTAssertEqual(viewModel.sharedContextDraft, "My edit.")

        await viewModel.saveSharedContext("My edit.")

        XCTAssertNil(viewModel.lastWriteError)
        XCTAssertNil(viewModel.sharedContextDraft)
        XCTAssertEqual(try String(contentsOf: project.contextURL, encoding: .utf8), "My edit.")
    }

    func testASaveWithTheFileUnchangedLandsFirstTime() async throws {
        try "Text A.".write(to: project.contextURL, atomically: true, encoding: .utf8)
        try "Text A.".write(to: fleetKnowledgeURL, atomically: true, encoding: .utf8)
        let viewModel = MemoryViewModel(memoryManager: MemoryManager(project: project))
        await viewModel.refresh()
        viewModel.sharedContextDraft = "Context edit."
        viewModel.fleetKnowledgeDraft = "Knowledge edit."
        await viewModel.refresh()

        await viewModel.saveSharedContext("Context edit.")
        XCTAssertNil(viewModel.lastWriteError)
        await viewModel.saveFleetKnowledge("Knowledge edit.")
        XCTAssertNil(viewModel.lastWriteError)

        XCTAssertEqual(try String(contentsOf: project.contextURL, encoding: .utf8), "Context edit.")
        XCTAssertEqual(try String(contentsOf: fleetKnowledgeURL, encoding: .utf8), "Knowledge edit.")
    }

    func testARevertedDraftTakesANewBaseline() async throws {
        try "Text A.".write(to: fleetKnowledgeURL, atomically: true, encoding: .utf8)
        let viewModel = MemoryViewModel(memoryManager: MemoryManager(project: project))
        await viewModel.refresh()
        viewModel.fleetKnowledgeDraft = "First edit."
        try "Text B.".write(to: fleetKnowledgeURL, atomically: true, encoding: .utf8)
        await viewModel.refresh()
        viewModel.revertFleetKnowledge()

        viewModel.fleetKnowledgeDraft = "Second edit, on B."
        await viewModel.saveFleetKnowledge("Second edit, on B.")

        XCTAssertNil(viewModel.lastWriteError)
        XCTAssertEqual(try String(contentsOf: fleetKnowledgeURL, encoding: .utf8), "Second edit, on B.")
    }
}
