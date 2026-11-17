import XCTest
@testable import KiteloopCore

/// What `POST /v1/runs` is asked for — one item or an ordered list — and the
/// order a list run walks.
///
/// The order is the point: a selection is a set, and the pickup pass walks it
/// lane first and then as the file is written, so a caller's "b, then a, then
/// c" had nowhere to live.
final class RunRequestTests: XCTestCase {

    // MARK: - The body

    func testASingleItemIsARequestForThatItemWithNoOrder() throws {
        let request = try parse(["project": "alpha", "item": "a"]).get()

        XCTAssertEqual(request, RunRequest(project: "alpha", ids: ["a"], isList: false))
        XCTAssertNil(request.requestedOrder, "one item's order says nothing, so the run is a plain start")
    }

    func testItemIdIsStillAcceptedForItem() throws {
        XCTAssertEqual(try parse(["project": "alpha", "itemId": "a"]).get().ids, ["a"])
    }

    func testAListKeepsTheOrderItWasPostedIn() throws {
        let request = try parse(["project": "alpha", "items": ["b", "a", "c"]]).get()

        XCTAssertEqual(request.ids, ["b", "a", "c"])
        XCTAssertEqual(request.requestedOrder, ["b", "a", "c"])
    }

    func testAListOfOneIsStillAList() throws {
        XCTAssertEqual(try parse(["project": "alpha", "items": ["a"]]).get().requestedOrder, ["a"])
    }

    func testBothFormsTogetherAreRefused() {
        XCTAssertEqual(message(["project": "alpha", "item": "a", "items": ["b"]]),
                       "Give either \"item\" or \"items\", not both")
        XCTAssertEqual(message(["project": "alpha", "itemId": "a", "items": ["b"]]),
                       "Give either \"item\" or \"items\", not both")
    }

    func testAnEmptyListIsRefused() {
        XCTAssertEqual(message(["project": "alpha", "items": [String]()]),
                       "\"items\" is empty — name at least one backlog item")
    }

    func testARepeatedIdIsRefusedByName() {
        XCTAssertEqual(message(["project": "alpha", "items": ["a", "b", "a"]]),
                       "\"items\" names 'a' more than once")
    }

    func testAListThatIsNotAllIdsIsRefused() {
        XCTAssertEqual(message(["project": "alpha", "items": ["a", 2]]),
                       "\"items\" must be an array of backlog item ids")
        XCTAssertEqual(message(["project": "alpha", "items": "a"]),
                       "\"items\" must be an array of backlog item ids")
    }

    func testABodyNamingNoItemOrNoProjectIsRefusedWithBothShapes() {
        for body: [String: Any] in [["project": "alpha"], ["item": "a"], ["items": ["a"]]] {
            XCTAssertEqual(message(body), RunRequest.shape, "\(body)")
        }
        guard case .failure(let invalid) = RunRequest.parse(Data("not json".utf8)) else {
            return XCTFail("a body that is not JSON is not a request")
        }
        XCTAssertEqual(invalid.message, RunRequest.shape)
    }

    func testTheFirstUnknownIdIsTheFirstInTheOrderGiven() {
        let request = RunRequest(project: "alpha", ids: ["b", "ghost", "a", "phantom"], isList: true)

        XCTAssertEqual(request.firstUnknown(among: ["a", "b"]), "ghost")
        XCTAssertNil(request.firstUnknown(among: ["a", "b", "ghost", "phantom"]))
    }

    // MARK: - The order

    /// The order asked for wins over both things that would otherwise decide:
    /// `a` is first in the file and `c` is the only `now` item.
    func testARequestedOrderWinsOverLaneAndFileOrder() {
        let items = [item("a"), item("b"), item("c", lane: .now)]

        XCTAssertEqual(RunRequest.runOrder(items, requested: ["b", "a", "c"]).map(\.id), ["b", "a", "c"])
    }

    func testWithNoRequestedOrderTheLaneStillDecides() {
        let items = [item("a"), item("b"), item("c", lane: .now)]

        XCTAssertEqual(RunRequest.runOrder(items, requested: nil).map(\.id), ["c", "a", "b"])
        XCTAssertEqual(RunRequest.runOrder(items, requested: nil), BacklogLane.ordered(items))
    }

    /// A gate that turned an item away before the order was applied leaves a
    /// gap, not a reshuffle: what is left still runs in the order given.
    func testAnItemMissingFromTheQueueLeavesTheRestInTheOrderGiven() {
        XCTAssertEqual(RunRequest.runOrder([item("a"), item("c")], requested: ["c", "b", "a"]).map(\.id),
                       ["c", "a"])
    }

    func testAnItemTheOrderDoesNotNameFollowsTheOnesItDoes() {
        let items = [item("a"), item("b"), item("c", lane: .now)]

        XCTAssertEqual(RunRequest.runOrder(items, requested: ["b"]).map(\.id), ["b", "c", "a"])
    }

    func testThePositionIsTheItemInFlightsPlaceInTheOrder() {
        XCTAssertEqual(RunRequest.position(of: "a", in: ["b", "a", "c"]), 1)
        XCTAssertNil(RunRequest.position(of: nil, in: ["b", "a", "c"]), "nothing in flight has no position")
        XCTAssertNil(RunRequest.position(of: "ghost", in: ["b", "a", "c"]))
    }

    // MARK: - Fixtures

    private func parse(_ body: [String: Any]) -> Result<RunRequest, RunRequest.Invalid> {
        RunRequest.parse((try? JSONSerialization.data(withJSONObject: body)) ?? Data())
    }

    private func message(_ body: [String: Any]) -> String? {
        guard case .failure(let invalid) = parse(body) else { return nil }
        return invalid.message
    }

    private func item(_ id: String, lane: BacklogLane = .later) -> BacklogItem {
        var item = BacklogItem(id: id, title: id.uppercased(), verify: "true",
                               status: .ready, type: .local, size: .s)
        item.lane = lane
        return item
    }
}
