import XCTest
@testable import KiteloopCore

final class DoneOutsideARunTests: XCTestCase {

    private func decide(_ status: BacklogItemStatus, approve: Bool? = nil, reason: String? = "merged by hand in abc123",
                        unmergedBranch: String? = nil) -> DoneOutsideARun.Verdict {
        DoneOutsideARun.decide(itemID: "item-1", status: status, approve: approve, reason: reason,
                               unmergedBranch: unmergedBranch)
    }

    func testDraftReadyAndBlockedItemsMayBeMarkedDoneWithTheReasonAsTheNote() {
        for status in [BacklogItemStatus.draft, .ready, .blocked] {
            XCTAssertEqual(decide(status, reason: "  merged by hand in abc123\n"),
                           .allowed(note: "marked done by hand, built outside a run: merged by hand in abc123"),
                           "\(status)")
        }
    }

    func testAnExplicitApproveTrueChangesNothing() {
        XCTAssertEqual(decide(.draft, approve: true), decide(.draft))
    }

    func testAMissingOrBlankReasonIsA400() {
        for reason in [nil, "", "  \n"] as [String?] {
            guard case .refused(let status, let why) = decide(.draft, reason: reason) else {
                return XCTFail("a reason of \(String(describing: reason)) must be refused")
            }
            XCTAssertEqual(status, 400)
            XCTAssertTrue(why.contains("needs a \"reason\""), why)
        }
    }

    func testApproveFalseBesideItIsA400() {
        guard case .refused(let status, let why) = decide(.draft, approve: false) else {
            return XCTFail("a rejection cannot mark an item done")
        }
        XCTAssertEqual(status, 400)
        XCTAssertTrue(why.contains("\"approve\": false"), why)
    }

    func testAnItemARunHoldsOrAtItsGateIsA409NamingItsStatus() {
        for status in [BacklogItemStatus.active, .inReview, .awaitingApproval, .done] {
            guard case .refused(let code, let why) = decide(status) else {
                return XCTFail("\(status) must be refused")
            }
            XCTAssertEqual(code, 409, "\(status)")
            XCTAssertTrue(why.contains("Item 'item-1' is \(status.rawValue)"), why)
        }
    }

    func testEveryStatusIsEitherAllowedOrRefused() {
        let allowed = BacklogItemStatus.allCases.filter {
            DoneOutsideARun.statusRefusal(itemID: "item-1", status: $0) == nil
        }
        XCTAssertEqual(allowed, [.draft, .ready, .blocked])
    }

    func testAnUnmergedBranchIsA409NamingTheBranch() {
        guard case .refused(let status, let why) = decide(.blocked, unmergedBranch: "kiteloop/item-1") else {
            return XCTFail("unmerged work must be refused")
        }
        XCTAssertEqual(status, 409)
        XCTAssertTrue(why.contains("not merged"), why)
        XCTAssertTrue(why.contains("kiteloop/item-1"), why)
    }

    func testTheStatusIsNamedBeforeTheBranch() {
        guard case .refused(_, let why) = decide(.active, unmergedBranch: "kiteloop/item-1") else {
            return XCTFail("an active item must be refused")
        }
        XCTAssertTrue(why.contains("a run holds it"), why)
    }
}
