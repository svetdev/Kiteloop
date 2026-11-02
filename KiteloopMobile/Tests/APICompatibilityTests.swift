import XCTest
@testable import KiteloopMobile

/// The phone and the Mac checked against each other by `/health`'s
/// `apiVersion`: the side that is behind is the one the banner names.
final class APICompatibilityTests: XCTestCase {

    func testTheSameVersionMatchesAndSaysNothing() {
        XCTAssertEqual(APICompatibility.judge(macVersion: APICompatibility.phoneVersion), .matched)
        XCTAssertNil(APICompatibility.matched.banner(macName: "Work Mac"))
    }

    func testALowerOrMissingVersionNamesTheMacAsOutOfDate() {
        XCTAssertEqual(APICompatibility.judge(macVersion: APICompatibility.phoneVersion - 1), .macOutdated)
        XCTAssertEqual(APICompatibility.judge(macVersion: nil), .macOutdated, "a Mac older than the field")
        XCTAssertTrue(APICompatibility.macOutdated.banner(macName: "Work Mac")?.contains("Kiteloop on Work Mac is older") == true)
    }

    func testAHigherVersionNamesThePhone() {
        XCTAssertEqual(APICompatibility.judge(macVersion: APICompatibility.phoneVersion + 1), .phoneOutdated)
        XCTAssertTrue(APICompatibility.phoneOutdated.banner(macName: "Work Mac")?.contains("update the phone app") == true)
    }

    func testHealthCarriesTheNumber() throws {
        let health = try JSONDecoder().decode(Health.self, from: Data(#"{"status":"ok","version":"0.4.9","apiVersion":1}"#.utf8))
        XCTAssertEqual(health.apiVersion, 1)
        XCTAssertNil(try JSONDecoder().decode(Health.self, from: Data(#"{"status":"ok"}"#.utf8)).apiVersion)
    }
}
