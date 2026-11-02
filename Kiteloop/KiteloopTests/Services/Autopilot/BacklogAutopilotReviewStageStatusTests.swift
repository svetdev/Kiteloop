import XCTest
import KiteloopCore
@testable import Kiteloop

/// Covers `BacklogAutopilot.itemStatus(forNode:useReviewStage:)` — the one
/// decision behind the In Review column.
///
/// The Review stage was a stage a project could switch on and then watch stay
/// empty: `BacklogWorkflowConfig.useReviewStage` decided whether `.inReview`
/// appeared in `activeStages` — the pipeline in Project Settings and the board's
/// columns — while nothing ever wrote the status, so an item sat on Active for
/// the whole of the reviewer's pass. The run loop that now writes it is a poll
/// inside `awaitWorkflowCompletion`, which no unit test can reach, so the whole
/// judgement lives here instead: node id and the project's toggle in, the stage
/// the item belongs in out.
final class BacklogAutopilotReviewStageStatusTests: XCTestCase {

    // MARK: - With the stage enabled

    func testTheWorkerNodePutsTheItemBackOnActive() {
        XCTAssertEqual(
            BacklogAutopilot.itemStatus(forNode: "worker", useReviewStage: true),
            .active
        )
    }

    func testTheReviewerNodePutsTheItemInReview() {
        XCTAssertEqual(
            BacklogAutopilot.itemStatus(forNode: "reviewer", useReviewStage: true),
            .inReview
        )
    }

    /// The follow-up ask is the same attempt, still waiting on the same verdict —
    /// the panel keeps reading `.reviewing` through it, and so does the board.
    func testTheClarifyNodeIsStillReview() {
        XCTAssertEqual(
            BacklogAutopilot.itemStatus(forNode: BacklogAutopilot.reviewerClarifyNodeID,
                                        useReviewStage: true),
            .inReview
        )
    }

    /// What `done` and `blocked` write is the run's outcome, decided where the
    /// item finishes rather than where it has got to — so this answers nothing
    /// for them, enabled or not.
    func testTerminalNodesMoveTheItemNowhere() {
        for node in ["done", "blocked"] {
            XCTAssertNil(BacklogAutopilot.itemStatus(forNode: node, useReviewStage: true), node)
            XCTAssertNil(BacklogAutopilot.itemStatus(forNode: node, useReviewStage: false), node)
        }
    }

    // MARK: - With the stage disabled

    /// A project whose flow has no Review column keeps exactly the statuses it
    /// has today: the item takes the `.active` it got at pickup through both
    /// nodes, and nothing here moves it.
    func testNoNodeMovesTheItemWhenTheStageIsOff() {
        for node in ["worker", "reviewer", BacklogAutopilot.reviewerClarifyNodeID] {
            XCTAssertNil(BacklogAutopilot.itemStatus(forNode: node, useReviewStage: false), node)
        }
    }

    /// The stage it writes is one the board actually draws — the column and the
    /// status cannot drift apart, since the same toggle decides both.
    func testTheStageItWritesIsOneTheBoardShows() {
        var config = BacklogWorkflowConfig.default
        config.useReviewStage = true

        let stage = BacklogAutopilot.itemStatus(forNode: "reviewer", useReviewStage: true)

        XCTAssertNotNil(stage)
        XCTAssertTrue(config.activeStages.contains(stage!))
    }
}
