import XCTest
@testable import KiteloopCore

final class PairingRemedyTests: XCTestCase {
    func testCheckingRendersTheSameHeadlineRegardlessOfServerState() {
        for serverRunning in [true, false] {
            let remedy = PairingRemedy.banner(for: .checking, address: "100.64.1.2", port: 4517, serverRunning: serverRunning)

            XCTAssertEqual(remedy.headline, "Checking 100.64.1.2:4517…")
            XCTAssertNil(remedy.remedy)
        }
    }

    func testReachableRendersTheSameHeadlineRegardlessOfServerState() {
        for serverRunning in [true, false] {
            let remedy = PairingRemedy.banner(for: .reachable, address: "100.64.1.2", port: 4517, serverRunning: serverRunning)

            XCTAssertEqual(remedy.headline, "100.64.1.2:4517 is reachable.")
            XCTAssertNil(remedy.remedy)
        }
    }

    func testUnreachableWithServerRunningNamesTheForwarderScript() {
        let remedy = PairingRemedy.banner(for: .unreachable, address: "100.64.1.2", port: 4517, serverRunning: true)

        XCTAssertEqual(remedy.headline, "Nothing answers at 100.64.1.2:4517 — the phone would hang.")
        XCTAssertEqual(remedy.remedy, "Run ./scripts/install-control-forwarder.sh on this Mac so the phone can reach it.")
    }

    func testUnreachableWithServerStoppedPointsAtTheToggleInstead() {
        let remedy = PairingRemedy.banner(for: .unreachable, address: "100.64.1.2", port: 4517, serverRunning: false)

        XCTAssertEqual(remedy.headline, "The control server isn't running — the phone would hang.")
        XCTAssertEqual(remedy.remedy, "Turn on the control server above, then pair again.")
        XCTAssertFalse(remedy.headline.contains("install-control-forwarder.sh"))
        XCTAssertFalse((remedy.remedy ?? "").contains("install-control-forwarder.sh"))
    }
}
