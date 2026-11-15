import XCTest
import SwiftUI
import KiteloopCore
import KiteloopTestSupport
@testable import Kiteloop

/// The Memory tab's page over the Claude CLI's notes: what it lists, what it
/// says, and that a save or a delete lands on disk — or says why it did not.
@MainActor
final class ClaudeMemoryViewModelTests: XCTestCase {
    private var store: ClaudeMemoryStore!

    /// A project's memory folder holding an index and two notes.
    private func makeNotes() throws {
        let base = try makeTemporaryDirectory()
        let project = base.appending(path: "project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        store = ClaudeMemoryStore(projectRoot: project, configDirectory: base.appending(path: "claude"))
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try write("- [Osprey](osprey.md) — staging\n- [Tone](tone.md) — replies\n", as: "MEMORY")
        try write("---\nname: Osprey\ndescription: the staging server\nmetadata:\n  type: project\n---\n\nStaging is osprey.\n", as: "osprey")
        try write("---\nname: Tone\ndescription: how to reply\ntype: feedback\n---\n\nShort replies.\n", as: "tone")
    }

    private func write(_ text: String, as id: String) throws {
        try text.write(to: store.directory.appending(path: "\(id).md"), atomically: true, encoding: .utf8)
    }

    private func loaded() async throws -> ClaudeMemoryViewModel {
        try makeNotes()
        let viewModel = ClaudeMemoryViewModel(store: store)
        await viewModel.refresh()
        return viewModel
    }

    func testThePageListsTheIndexThenTheNotesAndCountsOnlyTheNotes() async throws {
        let viewModel = try await loaded()
        XCTAssertEqual(viewModel.notes.map(\.id), ["MEMORY", "osprey", "tone"])
        XCTAssertEqual(viewModel.noteCount, 2)
    }

    func testTheFilterNarrowsByNameSummaryOrText() async throws {
        let viewModel = try await loaded()
        viewModel.filter = "  STAGING "
        XCTAssertEqual(viewModel.shownNotes.map(\.id), ["MEMORY", "osprey"])
        viewModel.filter = "short replies"
        XCTAssertEqual(viewModel.shownNotes.map(\.id), ["tone"])
        viewModel.filter = ""
        XCTAssertEqual(viewModel.shownNotes.count, 3)
    }

    func testThePageSaysHowManyNotesThereAre() {
        XCTAssertTrue(ClaudeMemoryViewModel.subtitle(noteCount: 0).hasPrefix("No notes yet."))
        XCTAssertEqual(ClaudeMemoryViewModel.subtitle(noteCount: 1), "1 note, written by the Claude CLI in this project's chats.")
        XCTAssertEqual(ClaudeMemoryViewModel.subtitle(noteCount: 41), "41 notes, written by the Claude CLI in this project's chats.")
    }

    func testTheSidebarRowCarriesTheCountOnceThereAreNotes() {
        XCTAssertEqual(MemoryBrowserView.claudeMemoryLabel(noteCount: 0), "Claude's memory")
        XCTAssertEqual(MemoryBrowserView.claudeMemoryLabel(noteCount: 7), "Claude's memory (7)")
    }

    func testASavedEditReachesTheFileAndClosesTheEditor() async throws {
        let viewModel = try await loaded()
        let note = try XCTUnwrap(viewModel.notes.first { $0.id == "tone" })
        viewModel.openEdit(note)
        XCTAssertTrue(viewModel.isEditing(note))
        viewModel.updateEdit(text: "Long replies.")

        await viewModel.saveEdit()

        XCTAssertEqual(store.text(of: "tone"), "Long replies.")
        XCTAssertNil(viewModel.edit)
        XCTAssertNil(viewModel.lastWriteError)
        XCTAssertEqual(viewModel.notes.first { $0.id == "tone" }?.text, "Long replies.")
    }

    func testANoteTheCLIChangedMeanwhileIsNotWrittenOverUntilTheSecondSave() async throws {
        let viewModel = try await loaded()
        let note = try XCTUnwrap(viewModel.notes.first { $0.id == "tone" })
        viewModel.openEdit(note)
        viewModel.updateEdit(text: "Mine.")
        try write("The CLI's.", as: "tone")

        await viewModel.saveEdit()
        XCTAssertEqual(store.text(of: "tone"), "The CLI's.")
        XCTAssertEqual(viewModel.lastWriteError, MemoryViewModel.changedOnDiskMessage)
        XCTAssertEqual(viewModel.edit?.text, "Mine.")

        await viewModel.saveEdit()
        XCTAssertEqual(store.text(of: "tone"), "Mine.")
        XCTAssertNil(viewModel.lastWriteError)
        XCTAssertNil(viewModel.edit)
    }

    func testCancellingAnEditWritesNothing() async throws {
        let viewModel = try await loaded()
        let note = try XCTUnwrap(viewModel.notes.first { $0.id == "tone" })
        viewModel.openEdit(note)
        viewModel.updateEdit(text: "Dropped.")
        viewModel.cancelEdit()
        XCTAssertNil(viewModel.edit)
        XCTAssertEqual(store.text(of: "tone"), note.text)
    }

    func testDeletingANoteRemovesItFromTheListAndTheIndex() async throws {
        let viewModel = try await loaded()
        let note = try XCTUnwrap(viewModel.notes.first { $0.id == "osprey" })
        viewModel.openEdit(note)

        await viewModel.delete(note)

        XCTAssertEqual(viewModel.notes.map(\.id), ["MEMORY", "tone"])
        XCTAssertEqual(store.text(of: "MEMORY"), "- [Tone](tone.md) — replies\n")
        XCTAssertNil(viewModel.edit)
        XCTAssertNil(viewModel.lastWriteError)
    }

    func testADeleteThatFailsSaysSo() async throws {
        let viewModel = try await loaded()
        await viewModel.delete(ClaudeMemoryNote(id: "gone", text: ""))
        XCTAssertEqual(viewModel.lastWriteError?.hasPrefix("Could not delete the note:"), true)
        XCTAssertEqual(viewModel.noteCount, 2)
    }

    func testThePageDrawsItsNotes() async throws {
        let viewModel = try await loaded()
        let host = NSHostingView(rootView: ClaudeMemoryPane(viewModel: viewModel).frame(width: 700, height: 600))
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.height, 0)
    }
}
