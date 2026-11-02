import XCTest
import KiteloopCore
@testable import Kiteloop

/// Reordering is prioritisation: the queue is document order, so `moveItem(itemID:before:)`
/// is the whole priority mechanism. These cases pin the three shapes it has — to the top
/// of its own epic, in front of a named item, and in front of an item in another epic —
/// and the two refusals: an unknown `before` writes nothing, and a no-op move stays put.
@MainActor
final class BacklogViewModelReorderTests: XCTestCase {
    private var tempDir: URL!
    private var viewModel: BacklogViewModel!

    override func setUpWithError() throws {
        tempDir = try makeTemporaryDirectory(prefix: "backlog-reorder")
        let backlog = """
        # Test Backlog

        ## Epic: First
        - [ ] a-one | A one | verify: true | size:S
        - [ ] a-two | A two | verify: true | size:S
        - [ ] a-three | A three | verify: true | size:S

        ## Epic: Second
        - [ ] b-one | B one | verify: true | size:S
        """
        try backlog.write(to: tempDir.appending(path: "BACKLOG.md"), atomically: true, encoding: .utf8)
        viewModel = BacklogViewModel(
            globalConfigStore: GlobalConfigStore(storageURL: tempDir.appending(path: "global-config.json")))
        viewModel.loadForProject(repoPath: tempDir.path(percentEncoded: false))
    }

    private func order(_ epic: String) -> [String] {
        viewModel.backlogFile?.sections.first { $0.name == epic }?.items.map(\.id) ?? []
    }

    func testMoveToTopOfItsOwnEpic() {
        viewModel.moveItem(itemID: "a-three", before: nil)
        XCTAssertEqual(order("First"), ["a-three", "a-one", "a-two"])
    }

    func testMoveInFrontOfANamedItem() {
        viewModel.moveItem(itemID: "a-one", before: "a-three")
        XCTAssertEqual(order("First"), ["a-two", "a-one", "a-three"])
    }

    func testMovingInFrontOfAnItemInAnotherEpicFollowsIt() {
        viewModel.moveItem(itemID: "a-two", before: "b-one")
        XCTAssertEqual(order("First"), ["a-one", "a-three"])
        XCTAssertEqual(order("Second"), ["a-two", "b-one"])
    }

    func testAnUnknownBeforeMovesNothing() {
        viewModel.moveItem(itemID: "a-two", before: "no-such-item")
        XCTAssertEqual(order("First"), ["a-one", "a-two", "a-three"],
                       "an unknown target is a no-op — nothing moves and nothing is written")
    }

    func testMovingAnItemInFrontOfItselfIsANoOp() {
        viewModel.moveItem(itemID: "a-two", before: "a-two")
        XCTAssertEqual(order("First"), ["a-one", "a-two", "a-three"])
    }

    func testTheOrderSurvivesTheWriteBack() throws {
        viewModel.moveItem(itemID: "a-three", before: nil)
        let written = try String(contentsOf: tempDir.appending(path: "BACKLOG.md"), encoding: .utf8)
        let firstIdx = try XCTUnwrap(written.range(of: "a-three")).lowerBound
        let secondIdx = try XCTUnwrap(written.range(of: "a-one")).lowerBound
        XCTAssertLessThan(firstIdx, secondIdx, "document order is the queue; the file carries the new priority")
    }

    private func epics() -> [String] {
        viewModel.backlogFile?.sections.map(\.name) ?? []
    }

    private func writtenBacklog() throws -> String {
        try String(contentsOf: tempDir.appending(path: "BACKLOG.md"), encoding: .utf8)
    }

    func testMovingAnEpicUpSwapsItWithItsNeighbourOnDisk() throws {
        viewModel.moveEpic(name: "Second", by: -1)
        XCTAssertEqual(epics(), ["Second", "First"])
        let written = try writtenBacklog()
        let second = try XCTUnwrap(written.range(of: "## Epic: Second")).lowerBound
        let first = try XCTUnwrap(written.range(of: "## Epic: First")).lowerBound
        XCTAssertLessThan(second, first, "the file carries the new epic order")
    }

    func testMovingAnEpicKeepsItsItemsInOrder() {
        viewModel.moveEpic(name: "First", by: 1)
        XCTAssertEqual(epics(), ["Second", "First"])
        XCTAssertEqual(order("First"), ["a-one", "a-two", "a-three"])
    }

    func testMovingPastEitherEndChangesNothing() throws {
        let before = try writtenBacklog()
        viewModel.moveEpic(name: "First", by: -1)
        viewModel.moveEpic(name: "Second", by: 1)
        XCTAssertEqual(epics(), ["First", "Second"])
        XCTAssertEqual(try writtenBacklog(), before)
        XCTAssertFalse(viewModel.canMoveEpic(name: "First", by: -1))
        XCTAssertFalse(viewModel.canMoveEpic(name: "Second", by: 1))
        XCTAssertTrue(viewModel.canMoveEpic(name: "First", by: 1))
    }

    func testAnUnknownEpicChangesNothingAndWritesNothing() throws {
        let before = try writtenBacklog()
        viewModel.moveEpic(name: "No Such Epic", by: -1)
        XCTAssertEqual(epics(), ["First", "Second"])
        XCTAssertEqual(try writtenBacklog(), before)
        XCTAssertFalse(viewModel.canMoveEpic(name: "No Such Epic", by: 1))
    }
}
