import XCTest
@testable import KiteloopMobile

/// What a scanned pairing QR says: a one-time code to trade for a token, or
/// the token itself from a Mac that keeps no paired phones.
final class PairingLinkTests: XCTestCase {

    func testACodeLinkCarriesTheCodeTheMacAndItsName() throws {
        let link = try XCTUnwrap(PairingLink("kiteloop://connect?base=http://100.64.0.1:4517&code=ab12&name=Work%20Mac"))

        XCTAssertEqual(link.base, "http://100.64.0.1:4517")
        XCTAssertEqual(link.credential, .code("ab12"))
        XCTAssertEqual(link.name, "Work Mac")
    }

    func testATokenLinkFromAnOlderMacStillPairs() throws {
        let link = try XCTUnwrap(PairingLink("kiteloop://connect?base=http://10.0.0.2:4517&token=cafe"))

        XCTAssertEqual(link.credential, .token("cafe"))
        XCTAssertNil(link.name)
    }

    func testACodeWinsOverATokenInTheSameLink() throws {
        let link = try XCTUnwrap(PairingLink("kiteloop://connect?base=http://h:1&token=t&code=c"))
        XCTAssertEqual(link.credential, .code("c"))
    }

    func testAnythingElseIsNotAPairingCode() {
        XCTAssertNil(PairingLink("https://example.com/?base=x&code=y"))
        XCTAssertNil(PairingLink("kiteloop://connect?base=http://h:1"))
        XCTAssertNil(PairingLink("kiteloop://connect?code=c"))
        XCTAssertNil(PairingLink("kiteloop://connect?base=&code=c"))
    }
}
