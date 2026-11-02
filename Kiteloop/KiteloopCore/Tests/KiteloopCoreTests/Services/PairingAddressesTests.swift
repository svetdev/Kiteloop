import XCTest
@testable import KiteloopCore

/// `PairingAddresses` exists so the pairing sheet's reachability rule is
/// tested in one place rather than three text-prefix comparisons buried in a
/// private SwiftUI view. The cases pin the octet boundaries a text prefix
/// gets wrong: 172.16/12 dropped entirely, and 100.64.0.0/10 (Tailscale's
/// actual CGNAT range) confused with anything starting `100.`.
final class PairingAddressesTests: XCTestCase {

    func testKeeps172_16Slash12ThatATextPrefixWouldDrop() {
        XCTAssertEqual(PairingAddresses.reachable(from: ["172.20.4.9"]), ["172.20.4.9"])
    }

    func testDropsAddressesJustOutsideThe172Slash12Boundary() {
        XCTAssertEqual(PairingAddresses.reachable(from: ["172.15.0.1", "172.32.0.1"]), [])
    }

    func testClassifiesTheCGNATRangeAsTailnetAndDropsAddressesJustOutsideIt() {
        XCTAssertEqual(
            PairingAddresses.reachable(from: ["100.64.0.1", "100.127.255.254", "100.63.0.1", "100.128.0.1"]),
            ["100.64.0.1", "100.127.255.254"]
        )
    }

    func testTailnetSortsFirstRegardlessOfInputOrderAndDuplicatesCollapse() {
        XCTAssertEqual(
            PairingAddresses.reachable(from: ["10.0.0.5", "10.0.0.6", "10.0.0.5", "100.64.1.1"]),
            ["100.64.1.1", "10.0.0.5", "10.0.0.6"]
        )
    }

    func testDropsLinkLocalAndPublicAddresses() {
        XCTAssertEqual(PairingAddresses.reachable(from: ["169.254.1.1", "8.8.8.8"]), [])
    }

    func testLabelsTailnetAndLAN() {
        XCTAssertEqual(PairingAddresses.label(for: "100.64.0.1"), "Tailnet")
        XCTAssertEqual(PairingAddresses.label(for: "172.20.4.9"), "Wi-Fi")
    }
}
