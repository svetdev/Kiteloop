import KiteloopCore
import XCTest
@testable import Kiteloop

/// A task's description in the chat's Agent Tasks panel: one line while the
/// row is folded, every line once it is clicked open. It used to be cut to one
/// line with nothing to reveal the rest.
final class AgentTaskDescriptionLineLimitTests: XCTestCase {

    func testAFoldedRowShowsOneLine() {
        XCTAssertEqual(AgentTaskPanelView.descriptionLineLimit(isExpanded: false), 1)
    }

    func testAnExpandedRowShowsEveryLine() {
        XCTAssertNil(AgentTaskPanelView.descriptionLineLimit(isExpanded: true))
    }

    // MARK: - The task the list scrolls to

    private func tasks(_ statuses: [AgentTask.TaskStatus]) -> [AgentTask] {
        statuses.enumerated().map { index, status in
            AgentTask(id: "t\(index + 1)", subject: "Task \(index + 1)", description: "", status: status,
                      agentID: "agent", createdAt: Date(), updatedAt: Date())
        }
    }

    func testTheTaskInProgressIsRevealedEvenBelowTheFold() {
        var statuses = Array(repeating: AgentTask.TaskStatus.pending, count: 12)
        statuses[8] = .inProgress
        XCTAssertEqual(AgentTaskPanelView.taskIDToReveal(in: tasks(statuses)), "t9")
    }

    func testWithNothingInProgressTheFirstPendingTaskIsRevealed() {
        let list = tasks([.completed, .completed, .pending, .pending])
        XCTAssertEqual(AgentTaskPanelView.taskIDToReveal(in: list), "t3")
    }

    func testNothingIsRevealedWhenEveryTaskIsCompletedOrThereAreNone() {
        XCTAssertNil(AgentTaskPanelView.taskIDToReveal(in: tasks([.completed, .completed, .completed])))
        XCTAssertNil(AgentTaskPanelView.taskIDToReveal(in: []))
    }

    func testWithTwoTasksInProgressTheFirstIsRevealed() {
        let list = tasks([.completed, .inProgress, .pending, .inProgress])
        XCTAssertEqual(AgentTaskPanelView.taskIDToReveal(in: list), "t2")
    }
}
