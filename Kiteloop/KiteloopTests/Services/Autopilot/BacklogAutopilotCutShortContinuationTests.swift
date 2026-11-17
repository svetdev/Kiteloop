import XCTest
import KiteloopCore
@testable import Kiteloop

/// The app-level half of `CutShortContinuation`: the state key a continuation
/// pass is started with, and the section it opens the worker's brief with.
/// When a continuation is due and what it blocks on is package code, tested
/// beside it in `CutShortContinuationTests`; whole continued runs are in
/// `BacklogAutopilotPreReviewGateRunTests`.
@MainActor
final class BacklogAutopilotCutShortContinuationTests: XCTestCase {

    private func workerPrompt(continuation: Bool) throws -> String {
        let item = BacklogItem(id: "abc", title: "Do the thing", verify: nil, status: .ready, type: .local, size: .s)
        let state = BacklogAutopilot.buildInitialState(item: item, detail: nil, worktree: nil,
                                                       continuation: continuation)
        let graph = BacklogAutopilot.buildWorkflowGraph(workerAgentID: "w", reviewerAgentID: "r", maxIterations: 3)
        return WorkflowStateTemplater.render(template: try XCTUnwrap(graph.nodes["worker"]?.prompt),
                                             state: state).rendered
    }

    func testAContinuationPassIsStartedWithTheNote() {
        let item = BacklogItem(id: "abc", title: "Do the thing", verify: nil, status: .ready, type: .local, size: .s)
        let state = BacklogAutopilot.buildInitialState(item: item, detail: nil, worktree: nil, continuation: true)
        XCTAssertEqual(state["continuationNote"], .string(CutShortContinuation.note))
    }

    func testAFirstPassCarriesNoContinuationNote() {
        let item = BacklogItem(id: "abc", title: "Do the thing", verify: nil, status: .ready, type: .local, size: .s)
        let state = BacklogAutopilot.buildInitialState(item: item, detail: nil, worktree: nil)
        XCTAssertNil(state["continuationNote"])
    }

    func testTheNoteOpensTheWorkersBriefOnAContinuation() throws {
        let prompt = try workerPrompt(continuation: true)
        let note = try XCTUnwrap(prompt.range(of: CutShortContinuation.note))
        let validation = try XCTUnwrap(prompt.range(of: "## Validation"))
        XCTAssertLessThan(note.lowerBound, validation.lowerBound)
        XCTAssertTrue(prompt.contains("git status"))
    }

    func testTheSectionIsAbsentFromAFirstPass() throws {
        let prompt = try workerPrompt(continuation: false)
        XCTAssertFalse(prompt.contains("Continuing unfinished work"))
        XCTAssertFalse(prompt.contains("continuationNote"))
    }
}
