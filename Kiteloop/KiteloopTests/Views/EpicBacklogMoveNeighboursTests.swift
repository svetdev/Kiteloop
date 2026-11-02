import XCTest
import KiteloopCore
@testable import Kiteloop

/// Move Up and Move Down step one place among the rows an epic draws: Up goes
/// in front of the previous shown row, Down puts the next shown row in front
/// of this one, and either is disabled where its neighbour is nil.
final class EpicBacklogMoveNeighboursTests: XCTestCase {

    func testFirstRowHasNoPreviousAndTheSecondAsNext() {
        let neighbours = EpicBacklogView.moveNeighbours(of: "a", in: ["a", "b", "c"])
        XCTAssertNil(neighbours.previous)
        XCTAssertEqual(neighbours.next, "b")
    }

    func testMiddleRowHasBothNeighbours() {
        let neighbours = EpicBacklogView.moveNeighbours(of: "b", in: ["a", "b", "c"])
        XCTAssertEqual(neighbours.previous, "a")
        XCTAssertEqual(neighbours.next, "c")
    }

    func testLastRowHasThePreviousAndNoNext() {
        let neighbours = EpicBacklogView.moveNeighbours(of: "c", in: ["a", "b", "c"])
        XCTAssertEqual(neighbours.previous, "b")
        XCTAssertNil(neighbours.next)
    }

    func testOnlyRowHasNowhereToGo() {
        let neighbours = EpicBacklogView.moveNeighbours(of: "a", in: ["a"])
        XCTAssertNil(neighbours.previous)
        XCTAssertNil(neighbours.next)
    }

    func testIDNotInTheListHasNoNeighbours() {
        let neighbours = EpicBacklogView.moveNeighbours(of: "z", in: ["a", "b", "c"])
        XCTAssertNil(neighbours.previous)
        XCTAssertNil(neighbours.next)
    }

    /// With completed rows hidden the shown list skips the done one, so Down
    /// on "a" swaps with "c" rather than with the hidden "b".
    func testAHiddenDoneRowIsSteppedOver() {
        let rows: [(id: String, status: BacklogItemStatus)] = [("a", .ready), ("b", .done), ("c", .ready)]
        let shownIDs = rows.filter {
            EpicBacklogView.isShown(status: $0.status, title: $0.id, id: $0.id, hidesCompleted: true, query: "")
        }.map(\.id)
        let neighbours = EpicBacklogView.moveNeighbours(of: "a", in: shownIDs)
        XCTAssertEqual(neighbours.next, "c")
    }
}
