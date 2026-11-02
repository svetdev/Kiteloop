import XCTest
import KiteloopCore
@testable import Kiteloop

/// Coverage for the Autopilot panel's merged item list — the rule that decides
/// which box owns an item during a run. The panel used to show the run's upcoming
/// items twice (Backlog *and* the Execution box's QUEUE section), so the load-
/// bearing assertion here is that a queued item appears exactly once.
final class AutopilotQueueListTests: XCTestCase {

    private func item(_ id: String, status: BacklogItemStatus = .ready) -> BacklogItem {
        BacklogItem(id: id, title: "Item \(id)", verify: nil, status: status, type: .local)
    }

    private func groups(
        sections: [BacklogSection],
        runQueue: [BacklogItem] = [],
        activeIndex: Int? = nil,
        selected: Set<String> = []
    ) -> [AutopilotQueueList.Group] {
        AutopilotQueueList.groups(
            sections: sections,
            pickupStages: [.ready],
            runQueue: runQueue,
            activeIndex: activeIndex,
            selectedItemIDs: selected
        )
    }

    private func ids(_ groups: [AutopilotQueueList.Group]) -> [String] {
        groups.flatMap(\.rows).map(\.id)
    }

    // MARK: - Idle

    /// With no run in flight every pickable item is a plain selectable row under
    /// its own section — the list the panel has always shown.
    func testIdleListsPickableItemsBySection() {
        let result = groups(sections: [
            BacklogSection(name: "Core", items: [item("a"), item("b", status: .done)]),
            BacklogSection(name: "UI", items: [item("c")]),
        ], selected: ["c"])

        XCTAssertEqual(result.map(\.title), ["Core", "UI"])
        XCTAssertFalse(result.contains { $0.isRunOrder })
        XCTAssertEqual(ids(result), ["a", "c"], "Only pickup-stage items are listed")
        XCTAssertEqual(result[0].rows[0].state, .selectable(isSelected: false))
        XCTAssertEqual(result[1].rows[0].state, .selectable(isSelected: true))
    }

    /// A section with nothing pickable in it contributes no heading.
    func testEmptySectionIsDropped() {
        let result = groups(sections: [
            BacklogSection(name: "Done", items: [item("a", status: .done)]),
            BacklogSection(name: "Core", items: [item("b")]),
        ])

        XCTAssertEqual(result.map(\.title), ["Core"])
    }

    // MARK: - During a run

    /// The regression this list exists for: an item the run still has ahead of it
    /// is a queued row and is *not* also offered as a selectable one.
    func testQueuedItemsAppearOnceAndOnlyInRunOrder() {
        let queue = [item("a"), item("b"), item("c")]
        let result = groups(
            sections: [BacklogSection(name: "Core", items: queue + [item("d")])],
            runQueue: queue,
            activeIndex: 0
        )

        XCTAssertEqual(result.map(\.title), ["Queue", "Core"])
        XCTAssertTrue(result[0].isRunOrder)
        XCTAssertEqual(ids(result), ["b", "c", "d"], "Each item renders exactly once")
        XCTAssertEqual(result[0].rows.map(\.state), [.queued(position: 2), .queued(position: 3)])
        XCTAssertEqual(result[1].rows.map(\.state), [.selectable(isSelected: false)])
    }

    /// The item in flight belongs to the Execution box, and finished ones to
    /// History — neither is repeated here.
    func testItemInFlightAndFinishedItemsAreNotListed() {
        let queue = [item("a", status: .done), item("b", status: .active), item("c")]
        let result = groups(
            sections: [BacklogSection(name: "Core", items: queue)],
            runQueue: queue,
            activeIndex: 1
        )

        XCTAssertEqual(ids(result), ["c"])
    }

    /// Positions are absolute in the run, not restarted at the top of what's
    /// left: "#4 in this run" has to mean the same thing all run long.
    func testQueuedPositionsAreAbsoluteRunPositions() {
        let queue = (1...5).map { item("i\($0)") }
        let result = groups(sections: [], runQueue: queue, activeIndex: 2)

        XCTAssertEqual(result[0].rows.map(\.state), [.queued(position: 4), .queued(position: 5)])
    }

    /// Run order is the information the group carries, so it survives whatever
    /// order the backlog file happens to list the same items in.
    func testRunOrderIsPreservedAgainstBacklogOrder() {
        // "c" is in flight, leaving "b" then "a" — the reverse of backlog order.
        let result = groups(
            sections: [BacklogSection(name: "Core", items: [item("a"), item("b"), item("c")])],
            runQueue: [item("c"), item("b"), item("a")],
            activeIndex: 0
        )

        XCTAssertEqual(ids(result), ["b", "a"])
    }

    /// The last item of a run leaves nothing queued behind it.
    func testNothingIsQueuedBehindTheFinalItem() {
        let queue = [item("a"), item("b")]
        let result = groups(sections: [], runQueue: queue, activeIndex: 1)

        XCTAssertTrue(result.isEmpty)
    }

    /// A cancelled item goes back to Ready but stays in the (now inert) run
    /// queue. Once the run is over it must be pickable again, not stuck behind a
    /// queue nobody is working through.
    func testFinishedRunLeavesItemsPickableAgain() {
        let queue = [item("a"), item("b")]
        let result = groups(
            sections: [BacklogSection(name: "Core", items: queue)],
            runQueue: queue,
            activeIndex: nil
        )

        XCTAssertEqual(result.map(\.title), ["Core"])
        XCTAssertEqual(ids(result), ["a", "b"])
        XCTAssertEqual(result[0].rows.map(\.state),
                       [.selectable(isSelected: false), .selectable(isSelected: false)])
    }

    // MARK: - Selection

    /// "All" and the "n selected" count are measured against the rows that
    /// actually have a checkbox, so a run holding three items can't inflate them.
    func testSelectableIDsExcludeQueuedRows() {
        let queue = [item("a"), item("b")]
        let result = groups(
            sections: [BacklogSection(name: "Core", items: queue + [item("c")])],
            runQueue: queue,
            activeIndex: 0
        )

        XCTAssertEqual(AutopilotQueueList.selectableIDs(in: result), ["c"])
    }

    /// Ticks left over from a finished run point at items the list no longer
    /// offers, so they select nothing — Run stays off and the toggle reads "All".
    func testPickableSelectionDropsRowsNoLongerOffered() {
        let result = groups(sections: [
            BacklogSection(name: "Core", items: [item("a", status: .done), item("c")]),
        ])

        XCTAssertEqual(AutopilotQueueList.pickableSelection(["a", "b"], in: result), [])
    }

    /// A mix of stale and live ticks keeps only the live ones — what a start sends.
    func testPickableSelectionKeepsOnlyOfferedIDs() {
        let result = groups(sections: [
            BacklogSection(name: "Core", items: [item("a", status: .done), item("c"), item("d")]),
        ])

        XCTAssertEqual(AutopilotQueueList.pickableSelection(["a", "b", "c"], in: result), ["c"])
    }

    /// A queued row is held by the run in flight, not offered, so a tick on it
    /// is not counted.
    func testPickableSelectionExcludesQueuedRows() {
        let queue = [item("a"), item("b")]
        let result = groups(
            sections: [BacklogSection(name: "Core", items: queue + [item("c")])],
            runQueue: queue,
            activeIndex: 0,
            selected: ["a", "b", "c"]
        )

        XCTAssertEqual(AutopilotQueueList.pickableSelection(["a", "b", "c"], in: result), ["c"])
    }

    /// Group ids distinguish the run-order group from a section that happens to
    /// be called "Queue", so `ForEach` can't collide the two.
    func testRunOrderGroupIDDiffersFromASectionNamedQueue() {
        let queue = [item("a"), item("b")]
        let result = groups(
            sections: [BacklogSection(name: "Queue", items: [item("c")])],
            runQueue: queue,
            activeIndex: 0
        )

        XCTAssertEqual(result.count, 2)
        XCTAssertNotEqual(result[0].id, result[1].id)
    }

    // MARK: - Row labels

    /// Rows lead with the id and follow it with the title, so the identifying
    /// half survives a narrow column.
    func testRowTitleIsTheTitleWhenItAddsSomething() {
        XCTAssertEqual(AutopilotQueueList.rowTitle(for: item("a")), "Item a")
    }

    /// A backlog line with no `| title` parses to an empty title. The row is then
    /// the id alone rather than an id followed by nothing.
    func testUntitledItemHasNoRowTitle() {
        XCTAssertNil(AutopilotQueueList.rowTitle(
            for: BacklogItem(id: "a", title: "", verify: nil, status: .ready, type: .local)))
        XCTAssertNil(AutopilotQueueList.rowTitle(
            for: BacklogItem(id: "a", title: "   ", verify: nil, status: .ready, type: .local)))
    }

    /// A title that only repeats the id is dropped too — the row already leads
    /// with it, and a second copy would take width from the size badge.
    func testTitleThatOnlyRepeatsTheIDIsDropped() {
        let echoed = BacklogItem(id: "fix-crash", title: "fix-crash", verify: nil, status: .ready, type: .local)

        XCTAssertNil(AutopilotQueueList.rowTitle(for: echoed))
    }

    // MARK: - The item in flight

    /// The row above the list names the item in flight and says whether the
    /// run is on it: a held run shows the pause mark, not a spinner that reads
    /// as work still happening.
    @MainActor
    func testAHeldRunMarksItsItemPausedAndAWorkingOneSpins() {
        XCTAssertEqual(AutopilotView.activeRunMark(for: .paused), .paused)
        XCTAssertEqual(AutopilotView.activeRunMark(for: .running(itemIndex: 0, total: 2)), .working)
        XCTAssertEqual(AutopilotView.activeRunMark(for: .reviewing(itemIndex: 1, total: 2, attempt: 2)), .working)
    }
}
