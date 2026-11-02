import XCTest
@testable import Kiteloop

/// What a project tab shows, and — the point of the rule — when it shows the
/// spinner. The tab used to be driven by token streaming alone, which goes false
/// for the whole of every tool call: a project 23 minutes into an `xcodebuild`
/// looked idle while the Autopilot panel beside it read `Running 1/1`.
final class ProjectTabIndicatorTests: XCTestCase {

    // MARK: - A run in flight

    /// The regression: a run is in flight and nothing is streaming — mid tool
    /// call, which is most of a run — and the tab must still say so.
    func testRunInFlightWithNoStreamingIsBusy() {
        XCTAssertEqual(
            ProjectTabIndicator.forProject(isRunning: true, isStreaming: false, isUnread: false),
            .busy
        )
    }

    /// The other half of the same run, while the model is emitting tokens.
    /// Unchanged from before, and it must stay that way through the transition.
    func testRunInFlightWhileStreamingIsBusy() {
        XCTAssertEqual(
            ProjectTabIndicator.forProject(isRunning: true, isStreaming: true, isUnread: false),
            .busy
        )
    }

    /// The run reaching a terminal state is the whole of what clears the spinner:
    /// nothing else about the project has to change.
    func testRunFinishingClearsTheSpinner() {
        XCTAssertEqual(
            ProjectTabIndicator.forProject(isRunning: false, isStreaming: false, isUnread: false),
            .idle
        )
    }

    // MARK: - Activity outside a run

    /// Someone chatting to an agent in a project with no run is activity too —
    /// binding to run state is a union with the streaming signal, not a
    /// replacement that loses it.
    func testStreamingWithoutARunStillShowsActivity() {
        XCTAssertEqual(
            ProjectTabIndicator.forProject(isRunning: false, isStreaming: true, isUnread: false),
            .busy
        )
    }

    // MARK: - Unread and idle

    /// Unread is what it was: shown when nothing is happening, and still beaten
    /// by activity — a project that is working hasn't finished anything you could
    /// have missed.
    func testUnreadShowsOnlyWhenNothingIsHappening() {
        XCTAssertEqual(
            ProjectTabIndicator.forProject(isRunning: false, isStreaming: false, isUnread: true),
            .unread
        )
        XCTAssertEqual(
            ProjectTabIndicator.forProject(isRunning: true, isStreaming: false, isUnread: true),
            .busy
        )
        XCTAssertEqual(
            ProjectTabIndicator.forProject(isRunning: false, isStreaming: true, isUnread: true),
            .busy
        )
    }

    /// A project with no session, or one whose run state couldn't be read, comes
    /// through as "not running" — unknown must read as the folder, never as a
    /// spinner nobody can clear.
    func testUnknownRunStateIsNotRunning() {
        XCTAssertEqual(
            ProjectTabIndicator.forProject(isRunning: false, isStreaming: false, isUnread: false),
            .idle
        )
    }
}

/// Which tab ⌘1…⌘9 and ⌘⇧[ / ⌘⇧] land on, over ids in tab-strip order.
extension ProjectTabIndicatorTests {
    private var ids: [String] { ["a", "b", "c"] }

    func testNumberPicksTheTabAtThatPosition() {
        XCTAssertEqual(ProjectTabNavigation.project(atShortcut: 1, in: ids), "a")
        XCTAssertEqual(ProjectTabNavigation.project(atShortcut: 2, in: ids), "b")
    }

    func testNumberPastTheLastTabIsNil() {
        XCTAssertNil(ProjectTabNavigation.project(atShortcut: 5, in: ids))
        XCTAssertNil(ProjectTabNavigation.project(atShortcut: 1, in: []))
    }

    func testNextOnTheLastTabWrapsToTheFirst() {
        XCTAssertEqual(ProjectTabNavigation.neighbour(of: "c", in: ids, offset: 1), "a")
        XCTAssertEqual(ProjectTabNavigation.neighbour(of: "a", in: ids, offset: 1), "b")
    }

    func testPreviousOnTheFirstTabWrapsToTheLast() {
        XCTAssertEqual(ProjectTabNavigation.neighbour(of: "a", in: ids, offset: -1), "c")
        XCTAssertEqual(ProjectTabNavigation.neighbour(of: "c", in: ids, offset: -1), "b")
    }

    func testNothingOpenIsNil() {
        XCTAssertNil(ProjectTabNavigation.neighbour(of: nil, in: [], offset: 1))
        XCTAssertNil(ProjectTabNavigation.neighbour(of: "a", in: [], offset: -1))
    }

    func testMissingOrNilActiveIDFallsBackToTheFirstTab() {
        XCTAssertEqual(ProjectTabNavigation.neighbour(of: "gone", in: ids, offset: 1), "a")
        XCTAssertEqual(ProjectTabNavigation.neighbour(of: nil, in: ids, offset: -1), "a")
    }

    // MARK: - Closing a project mid-run

    func testClosingAProjectWithNoRunInFlightNeedsNoPrompt() {
        XCTAssertNil(ProjectClosePrompt.message(isRunning: false, item: nil))
    }

    func testClosingMidRunNamesTheItemByTitle() {
        let item = ActiveOrchestratorTracker.InFlightItem(
            id: "fix-login", title: "Fix the login flow", projectPath: "/tmp/app")
        let message = ProjectClosePrompt.message(isRunning: true, item: item)
        XCTAssertTrue(message?.contains("Fix the login flow") == true, message ?? "nil")
    }

    func testClosingMidRunNamesAnUntitledItemByID() {
        let item = ActiveOrchestratorTracker.InFlightItem(id: "fix-login", title: "", projectPath: "/tmp/app")
        let message = ProjectClosePrompt.message(isRunning: true, item: item)
        XCTAssertTrue(message?.contains("fix-login") == true, message ?? "nil")
    }

    func testClosingMidRunWithNoKnownItemStillSaysARunIsInFlight() {
        let message = ProjectClosePrompt.message(isRunning: true, item: nil)
        XCTAssertTrue(message?.contains("run is in flight") == true, message ?? "nil")
    }
}
