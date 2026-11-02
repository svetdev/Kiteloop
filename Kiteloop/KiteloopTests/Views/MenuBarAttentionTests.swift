import XCTest
@testable import Kiteloop
@testable import KiteloopCore

/// What the menu bar says about work that has stopped and been handed back to a
/// person, and what the bar itself shows while it has.
///
/// The menu bar is the one Kiteloop surface still on screen when the window is
/// behind everything else, and it named the busy agents and the active project's
/// in-flight item and nothing else — a run parked at the approval gate was
/// visible only on the toolbar bell, inside the window, so the fleet stalled for
/// as long as it took somebody to come back and look.
final class MenuBarAttentionTests: XCTestCase {

    // MARK: - The headline

    /// Nothing waiting draws no section at all: a menu bar that says "0 waiting
    /// on you" asks to be read every time it is right about nothing.
    func testNothingWaitingHasNoHeadline() {
        XCTAssertNil(MenuBarAttention.headline(waiting: 0))
    }

    /// One gate is one *thing*, singular — the wording is the whole reason this
    /// is a function and not an interpolation at the call site.
    func testOneGateReadsSingular() {
        XCTAssertEqual(MenuBarAttention.headline(waiting: 1), "1 thing waiting on you")
    }

    func testSeveralGatesReadPlural() {
        XCTAssertEqual(MenuBarAttention.headline(waiting: 2), "2 things waiting on you")
        XCTAssertEqual(MenuBarAttention.headline(waiting: 7), "7 things waiting on you")
    }

    // MARK: - The waiting rows

    private func waitingRows(_ count: Int) -> [WaitingOnYou.Row] {
        (0..<count).map { index in
            WaitingOnYou.Row(
                id: "approval-a\(index)", projectID: "p1", projectName: "alpha",
                projectPath: "/tmp/alpha", gate: .approval(itemID: "a\(index)"),
                title: "Item \(index)", detail: nil, since: nil)
        }
    }

    /// Seven gates draw the first five, in order, and leave two for "+2 more".
    func testSevenWaitingRowsShowFiveAndOverflowTwo() {
        let rows = waitingRows(7)
        let visible = MenuBarAttention.visibleWaitingRows(rows)
        XCTAssertEqual(visible.rows, Array(rows.prefix(5)))
        XCTAssertEqual(visible.overflow, 2)
    }

    /// Three gates all fit, so there is no "+N more" line.
    func testThreeWaitingRowsAllShowWithNoOverflow() {
        let rows = waitingRows(3)
        let visible = MenuBarAttention.visibleWaitingRows(rows)
        XCTAssertEqual(visible.rows, rows)
        XCTAssertEqual(visible.overflow, 0)
    }

    /// An approval and a question in two projects are two rows, each naming its
    /// title and its project.
    @MainActor
    func testApprovalAndQuestionAreTwoRowsNamingTheirProjects() {
        let waiting = WaitingOnYou.capture(projects: [
            WaitingOnYou.ProjectReading(
                id: "p1", name: "alpha", path: "/tmp/alpha",
                gatedItems: [.init(id: "a1", title: "One")]),
            WaitingOnYou.ProjectReading(
                id: "p2", name: "beta", path: "/tmp/beta",
                askingAgents: [.init(id: "ada", name: "Ada")])
        ])
        let visible = MenuBarAttention.visibleWaitingRows(waiting.rows)
        XCTAssertEqual(visible.rows.count, 2)
        XCTAssertEqual(visible.overflow, 0)
        XCTAssertTrue(visible.rows.contains { $0.title == "One" && $0.subtitle.contains("alpha") })
        XCTAssertTrue(visible.rows.contains { $0.subtitle.contains("beta") })
    }

    /// Clicking the same row twice is two requests: the sequence number moves,
    /// so the window's `onChange` sees a new value both times.
    @MainActor
    func testPostingTheSameGateTwiceIsTwoRequests() throws {
        let tracker = ActiveOrchestratorTracker()
        let row = try XCTUnwrap(waitingRows(1).first)

        tracker.requestOpenGate(row)
        let first = try XCTUnwrap(tracker.openGateRequest)
        tracker.requestOpenGate(row)
        let second = try XCTUnwrap(tracker.openGateRequest)

        XCTAssertEqual(first.row, row)
        XCTAssertEqual(second.row, row)
        XCTAssertNotEqual(first, second)
    }

    /// A gate clicked with no window open has nobody observing it, so the
    /// request waits on the tracker until a window takes it — and is taken
    /// once, so the next window to drain finds nothing.
    @MainActor
    func testAGateRequestStaysPendingUntilTakenAndTakingClearsIt() throws {
        let tracker = ActiveOrchestratorTracker()
        let row = try XCTUnwrap(waitingRows(1).first)

        tracker.requestOpenGate(row)
        XCTAssertEqual(tracker.openGateRequest?.row, row)

        XCTAssertEqual(tracker.takeOpenGateRequest()?.row, row)
        XCTAssertNil(tracker.openGateRequest)
        XCTAssertNil(tracker.takeOpenGateRequest())
    }

    /// The same for an in-flight row's item, which posts the other request.
    @MainActor
    func testAnItemRequestStaysPendingUntilTakenAndTakingClearsIt() {
        let tracker = ActiveOrchestratorTracker()

        tracker.requestOpenItem("a1", in: .path("/tmp/alpha"))
        XCTAssertEqual(tracker.openItemRequest?.itemID, "a1")

        let taken = tracker.takeOpenItemRequest()
        XCTAssertEqual(taken?.itemID, "a1")
        XCTAssertEqual(taken?.project, .path("/tmp/alpha"))
        XCTAssertNil(tracker.openItemRequest)
        XCTAssertNil(tracker.takeOpenItemRequest())
    }

    // MARK: - What is running

    /// Nothing running draws no in-flight section at all — no divider and no
    /// empty row.
    func testNothingRunningDrawsNoRows() {
        XCTAssertTrue(MenuBarAttention.runningRows([]).isEmpty)
    }

    /// One run in flight is one row, and it names the item alone: with a single
    /// row there is nothing to tell it apart from.
    func testOneRunningProjectNamesTheItemAlone() {
        let rows = MenuBarAttention.runningRows([
            .init(id: "a1", title: "One", projectPath: "/tmp/alpha")
        ])
        XCTAssertEqual(rows.map(\.item.id), ["a1"])
        XCTAssertEqual(rows.map(\.item.headline), ["One"])
        XCTAssertEqual(rows.map(\.projectName), [nil])
    }

    /// The whole point of the change: a run in a project you are not looking at
    /// gets its own row, and each row then names its project folder.
    func testSeveralRunningProjectsEachNameTheirProject() {
        let rows = MenuBarAttention.runningRows([
            .init(id: "a1", title: "One", projectPath: "/tmp/alpha"),
            .init(id: "b1", title: "", projectPath: "/tmp/beta")
        ])
        XCTAssertEqual(rows.map(\.item.id), ["a1", "b1"])
        XCTAssertEqual(rows.map(\.projectName), ["alpha", "beta"])
        // An item with no title still opens, under its id.
        XCTAssertEqual(rows.map(\.item.headline), ["One", "b1"])
        // Each row links to its own project, not the one in front.
        XCTAssertEqual(rows.map(\.item.projectPath), ["/tmp/alpha", "/tmp/beta"])
        XCTAssertEqual(rows.map(\.id), ["/tmp/alpha", "/tmp/beta"])
    }

    /// The tracker starts with nothing running, so a launch draws no in-flight
    /// section either.
    @MainActor
    func testTrackerStartsWithNothingRunning() {
        let tracker = ActiveOrchestratorTracker()
        XCTAssertTrue(MenuBarAttention.runningRows(tracker.inFlightItems).isEmpty)
    }

    // MARK: - The label glyph

    /// The point of the glyph: the bar differs between the two states without
    /// being clicked.
    func testLabelGlyphDiffersBetweenWaitingAndNot() {
        XCTAssertEqual(MenuBarAttention.labelSymbol(waiting: false), "building.2")
        XCTAssertEqual(MenuBarAttention.labelSymbol(waiting: true), "building.2.fill")
        XCTAssertNotEqual(MenuBarAttention.labelSymbol(waiting: true),
                          MenuBarAttention.labelSymbol(waiting: false))
    }

    // MARK: - An agent's state

    /// Every state reads as a word, not its enum case — the one a person most
    /// needs to read at a glance is the agent waiting on them.
    func testEveryAgentStateReadsAsPlainEnglish() {
        XCTAssertEqual(MenuBarAttention.stateLabel(.idle), "idle")
        XCTAssertEqual(MenuBarAttention.stateLabel(.working), "working")
        XCTAssertEqual(MenuBarAttention.stateLabel(.waitingForHuman), "waiting on you")
        XCTAssertEqual(MenuBarAttention.stateLabel(.crashed), "stopped")
    }

    func testWaitingForHumanDoesNotPrintItsRawCase() {
        XCTAssertNotEqual(MenuBarAttention.stateLabel(.waitingForHuman),
                          Agent.AgentState.waitingForHuman.rawValue)
        XCTAssertNotEqual(MenuBarAttention.stateLabel(.crashed),
                          Agent.AgentState.crashed.rawValue)
    }

    // MARK: - What the tracker carries

    /// The tracker starts empty, so a launch with no projects open shows the
    /// plain glyph and no section.
    @MainActor
    func testTrackerStartsWithNothingWaiting() {
        let tracker = ActiveOrchestratorTracker()
        XCTAssertTrue(tracker.waiting.isEmpty)
        XCTAssertNil(MenuBarAttention.headline(waiting: tracker.waiting.rows.count))
        XCTAssertEqual(MenuBarAttention.labelSymbol(waiting: !tracker.waiting.isEmpty),
                       "building.2")
    }

    /// The counting the menu bar does is `WaitingOnYou`'s, across every open
    /// project — two projects each holding one item at the gate is two, and the
    /// summary beneath the headline still counts the kinds apart.
    @MainActor
    func testGatesInTwoProjectsCountTogether() {
        let tracker = ActiveOrchestratorTracker()
        tracker.waiting = WaitingOnYou.capture(projects: [
            WaitingOnYou.ProjectReading(
                id: "p1", name: "alpha", path: "/tmp/alpha",
                gatedItems: [.init(id: "a1", title: "One")]),
            WaitingOnYou.ProjectReading(
                id: "p2", name: "beta", path: "/tmp/beta",
                gatedItems: [.init(id: "b1", title: "Two")],
                askingAgents: [.init(id: "ada", name: "Ada")])
        ])

        XCTAssertEqual(MenuBarAttention.headline(waiting: tracker.waiting.rows.count),
                       "3 things waiting on you")
        XCTAssertEqual(tracker.waiting.summary, "2 approvals · 1 question")
        XCTAssertEqual(MenuBarAttention.labelSymbol(waiting: !tracker.waiting.isEmpty),
                       "building.2.fill")
    }

    /// A gate cleared between two ticks leaves the menu bar on the next one: the
    /// value is captured off the live backlog and chats, so the project simply
    /// arrives with no gated item and the row is gone.
    @MainActor
    func testClearedGateLeavesOnTheNextTick() {
        let tracker = ActiveOrchestratorTracker()
        tracker.waiting = WaitingOnYou.capture(projects: [
            WaitingOnYou.ProjectReading(
                id: "p1", name: "alpha", path: "/tmp/alpha",
                gatedItems: [.init(id: "a1", title: "One")])
        ])
        XCTAssertEqual(MenuBarAttention.headline(waiting: tracker.waiting.rows.count),
                       "1 thing waiting on you")

        tracker.waiting = WaitingOnYou.capture(projects: [
            WaitingOnYou.ProjectReading(id: "p1", name: "alpha", path: "/tmp/alpha")
        ])
        XCTAssertTrue(tracker.waiting.isEmpty)
        XCTAssertNil(MenuBarAttention.headline(waiting: tracker.waiting.rows.count))
        XCTAssertEqual(MenuBarAttention.labelSymbol(waiting: !tracker.waiting.isEmpty),
                       "building.2")
    }
}
