import XCTest
@testable import KiteloopCore

final class StartsInChecksTests: XCTestCase {

    func testAProjectWithNoStartDecidingIsNotRefused() {
        var starts = StartsInChecks()

        XCTAssertNil(starts.refusal(project: "alpha"))
        XCTAssertNil(starts.claim(project: "alpha", items: ["item-1"]))
    }

    func testASecondStartIsRefusedNamingTheItemTheFirstAskedFor() throws {
        var starts = StartsInChecks()
        XCTAssertNil(starts.claim(project: "alpha", items: ["item-1"]))

        let refusal = try XCTUnwrap(starts.claim(project: "alpha", items: ["item-1"]))

        XCTAssertTrue(refusal.contains("already in its pickup checks"), refusal)
        XCTAssertTrue(refusal.contains("item 'item-1'"), refusal)
        XCTAssertEqual(starts.refusal(project: "alpha"), refusal)
    }

    func testASecondStartForAnotherItemIsRefusedAndNamesTheFirstStartsList() throws {
        var starts = StartsInChecks()
        XCTAssertNil(starts.claim(project: "alpha", items: ["item-1", "item-2"]))

        let refusal = try XCTUnwrap(starts.claim(project: "alpha", items: ["item-3"]))

        XCTAssertTrue(refusal.contains("items 'item-1', 'item-2'"), refusal)
        XCTAssertFalse(refusal.contains("item-3"), "the refusal names the start that is deciding, not the refused one")
    }

    func testARefusedClaimLeavesTheFirstStartAsItWas() {
        var starts = StartsInChecks()
        XCTAssertNil(starts.claim(project: "alpha", items: ["item-1"]))
        let before = starts

        _ = starts.claim(project: "alpha", items: ["item-2"])

        XCTAssertEqual(starts, before)
    }

    func testAStartInOneProjectDoesNotRefuseAnother() {
        var starts = StartsInChecks()
        XCTAssertNil(starts.claim(project: "alpha", items: ["item-1"]))

        XCTAssertNil(starts.claim(project: "beta", items: ["item-1"]))
    }

    func testADecidedStartNoLongerRefusesTheNext() {
        var starts = StartsInChecks()
        XCTAssertNil(starts.claim(project: "alpha", items: ["item-1"]))

        starts.release(project: "alpha")

        XCTAssertNil(starts.refusal(project: "alpha"))
        XCTAssertNil(starts.claim(project: "alpha", items: ["item-2"]))
    }
}
