import XCTest
import KiteloopCore
@testable import Kiteloop

/// Covers the app-level half of `GateRejection`: rendering an outstanding
/// rejection into the worker's and the reviewer's prompt
/// (`BacklogAutopilot.buildInitialState`), and clearing one once a run passes
/// review (`BacklogAutopilot.clearGateRejectionIfOutstanding`). The ledger
/// logic itself — `outstanding`, `promptBlock`, persistence — is package code
/// and is tested beside it in `GateRejectionTests`.
@MainActor
final class GateRejectionAutopilotTests: XCTestCase {

    private func item() -> BacklogItem {
        BacklogItem(id: "abc", title: "Do the thing", verify: nil, status: .ready, type: .local, size: .m)
    }

    private func rejected(reason: String = "left the bug in place",
                          ref: String? = "refs/kiteloop/rejected/abc") -> GateRejection.Record {
        .init(itemID: "abc", kind: .rejected, reason: reason, ref: ref, at: Date())
    }

    private func renderedPrompts(rejection: GateRejection.Record?) throws -> (worker: String, reviewer: String) {
        let state = BacklogAutopilot.buildInitialState(item: item(), detail: nil, worktree: nil, rejection: rejection)
        let graph = BacklogAutopilot.buildWorkflowGraph(workerAgentID: "w", reviewerAgentID: "r", maxIterations: 3)
        func render(_ nodeID: String) throws -> String {
            WorkflowStateTemplater.render(template: try XCTUnwrap(graph.nodes[nodeID]?.prompt), state: state).rendered
        }
        return (try render("worker"), try render("reviewer"))
    }

    // MARK: - buildInitialState

    /// The first section after the title — the reason verbatim, and a ref that
    /// names the rejected run's tip.
    func testWorkerPromptOpensWithTheRejectionAndNamesTheRef() throws {
        let prompts = try renderedPrompts(rejection: rejected(
            reason: "the gateCommand mismatch is still there", ref: "refs/kiteloop/rejected/abc"))
        let worker = prompts.worker
        let title = try XCTUnwrap(worker.range(of: "Working on:"))
        let rejection = try XCTUnwrap(worker.range(of: "## Rejected last time"), worker)
        let what = try XCTUnwrap(worker.range(of: "## Validation"), worker)
        XCTAssertTrue(title.lowerBound < rejection.lowerBound)
        XCTAssertTrue(rejection.lowerBound < what.lowerBound, "the rejection is read before anything else")
        XCTAssertTrue(worker.contains("the gateCommand mismatch is still there"), worker)
        XCTAssertTrue(worker.contains("refs/kiteloop/rejected/abc"), worker)
        XCTAssertFalse(worker.contains("{{state.humanRejection}}"), "the placeholder survived into the prompt")
    }

    /// The reviewer prompt carries the identical text, plus its own
    /// instruction that leaving the defect in place is blocking.
    func testReviewerPromptCarriesTheSameTextAndTreatsItAsBlocking() throws {
        let reviewer = try renderedPrompts(rejection: rejected(
            reason: "the gateCommand mismatch is still there")).reviewer
        XCTAssertTrue(reviewer.contains("## Rejected last time"), reviewer)
        XCTAssertTrue(reviewer.contains("the gateCommand mismatch is still there"), reviewer)
        let flat = reviewer.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        XCTAssertTrue(flat.contains("is blocking, regardless of how many lines of Validation"), flat)
    }

    /// An item that was never rejected produces exactly today's prompts — no
    /// heading, no placeholder.
    func testPromptsCarryNoRejectionSectionWhenThereIsNone() throws {
        let prompts = try renderedPrompts(rejection: nil)
        XCTAssertFalse(prompts.worker.contains("Rejected last time"), prompts.worker)
        XCTAssertFalse(prompts.worker.contains("{{state.humanRejection}}"), prompts.worker)
        XCTAssertFalse(prompts.reviewer.contains("Rejected last time"), prompts.reviewer)
        XCTAssertFalse(prompts.reviewer.contains("{{state.humanRejection}}"), prompts.reviewer)
    }

    // MARK: - clearGateRejectionIfOutstanding

    func testClearingAnOutstandingRejectionMakesItNoLongerOutstanding() throws {
        let dir = try makeTemporaryDirectory(prefix: "gate-rejection-clear")
        let path = dir.path(percentEncoded: false)
        let url = GateRejection.url(projectPath: path)
        GateRejection.append(rejected(), to: url)
        XCTAssertNotNil(GateRejection.outstanding(itemID: "abc", entries: GateRejection.read(from: url)))

        BacklogAutopilot.clearGateRejectionIfOutstanding(itemID: "abc", projectPath: path)

        XCTAssertNil(GateRejection.outstanding(itemID: "abc", entries: GateRejection.read(from: url)))
    }

    /// An item with nothing outstanding writes nothing — the ledger a
    /// never-rejected item's every ordinary passing run would otherwise gain.
    func testClearingAnItemWithNothingOutstandingWritesNothing() throws {
        let dir = try makeTemporaryDirectory(prefix: "gate-rejection-clear-noop")
        let path = dir.path(percentEncoded: false)
        let url = GateRejection.url(projectPath: path)

        BacklogAutopilot.clearGateRejectionIfOutstanding(itemID: "abc", projectPath: path)

        XCTAssertTrue(GateRejection.read(from: url).isEmpty)
    }
}
